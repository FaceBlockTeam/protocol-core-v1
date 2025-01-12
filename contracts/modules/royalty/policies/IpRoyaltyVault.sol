// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
// solhint-disable-next-line max-line-length
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable-v4/security/ReentrancyGuardUpgradeable.sol";
// solhint-disable-next-line max-line-length
import { ERC20SnapshotUpgradeable } from "@openzeppelin/contracts-upgradeable-v4/token/ERC20/extensions/ERC20SnapshotUpgradeable.sol";
// solhint-disable-next-line max-line-length
import { SafeERC20Upgradeable } from "@openzeppelin/contracts-upgradeable-v4/token/ERC20/utils/SafeERC20Upgradeable.sol";
import { IERC20Upgradeable } from "@openzeppelin/contracts-upgradeable-v4/token/ERC20/IERC20Upgradeable.sol";

import { IVaultController } from "../../../interfaces/modules/royalty/policies/IVaultController.sol";
import { IDisputeModule } from "../../../interfaces/modules/dispute/IDisputeModule.sol";
import { IRoyaltyModule } from "../../../interfaces/modules/royalty/IRoyaltyModule.sol";
import { IIpRoyaltyVault } from "../../../interfaces/modules/royalty/policies/IIpRoyaltyVault.sol";
import { Errors } from "../../../lib/Errors.sol";

/// @title Ip Royalty Vault
/// @notice Defines the logic for claiming revenue tokens for a given IP
contract IpRoyaltyVault is IIpRoyaltyVault, ERC20SnapshotUpgradeable, ReentrancyGuardUpgradeable {
    using EnumerableSet for EnumerableSet.AddressSet;
    using SafeERC20Upgradeable for IERC20Upgradeable;

    /// @dev Storage structure for the IpRoyaltyVault
    /// @param ipId The ip id to whom this royalty vault belongs to
    /// @param lastSnapshotTimestamp The last snapshotted timestamp
    /// @param claimVaultAmount Amount of revenue token in the claim vault
    /// @param claimableAtSnapshot Amount of revenue token claimable at a given snapshot
    /// @param isClaimedAtSnapshot Indicates whether the claimer has claimed the revenue tokens at a given snapshot
    /// @param tokens The list of revenue tokens in the vault
    /// @custom:storage-location erc7201:story-protocol.IpRoyaltyVault
    struct IpRoyaltyVaultStorage {
        address ipId;
        uint40 lastSnapshotTimestamp;
        mapping(address token => uint256 amount) claimVaultAmount;
        mapping(uint256 snapshotId => mapping(address token => uint256 amount)) claimableAtSnapshot;
        mapping(uint256 snapshotId => mapping(address claimer => mapping(address token => bool))) isClaimedAtSnapshot;
        EnumerableSet.AddressSet tokens;
    }

    // keccak256(abi.encode(uint256(keccak256("story-protocol.IpRoyaltyVault")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant IpRoyaltyVaultStorageLocation =
        0xe1c3e3b0c445d504edb1b9e6fa2ca4fab60584208a4bc973fe2db2b554d1df00;

    /// @notice Dispute module address
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    IDisputeModule public immutable DISPUTE_MODULE;

    /// @notice Royalty module address
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    IRoyaltyModule public immutable ROYALTY_MODULE;

    modifier whenNotPaused() {
        // DEV NOTE: If we upgrade RoyaltyModule to not pausable, we need to remove this.
        if (PausableUpgradeable(address(ROYALTY_MODULE)).paused()) revert Errors.IpRoyaltyVault__EnforcedPause();
        _;
    }

    /// @notice Constructor
    /// @param disputeModule The address of the dispute module
    /// @param royaltyModule The address of the royalty module
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address disputeModule, address royaltyModule) {
        if (disputeModule == address(0)) revert Errors.IpRoyaltyVault__ZeroDisputeModule();
        if (royaltyModule == address(0)) revert Errors.IpRoyaltyVault__ZeroRoyaltyModule();

        DISPUTE_MODULE = IDisputeModule(disputeModule);
        ROYALTY_MODULE = IRoyaltyModule(royaltyModule);

        _disableInitializers();
    }

    /// @notice Initializer for this implementation contract
    /// @param name The name of the royalty token
    /// @param symbol The symbol of the royalty token
    /// @param supply The total supply of the royalty token
    /// @param ipIdAddress The ip id the royalty vault belongs to
    /// @param rtReceiver The address of the royalty token receiver
    function initialize(
        string memory name,
        string memory symbol,
        uint32 supply,
        address ipIdAddress,
        address rtReceiver
    ) external initializer {
        IpRoyaltyVaultStorage storage $ = _getIpRoyaltyVaultStorage();

        $.ipId = ipIdAddress;
        $.lastSnapshotTimestamp = uint40(block.timestamp);

        _mint(rtReceiver, supply);

        __ReentrancyGuard_init();
        __ERC20Snapshot_init();
        __ERC20_init(name, symbol);
    }

    /// @notice Returns the number royalty token decimals
    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /// @notice Adds a new revenue token to the vault
    /// @param token The address of the revenue token
    /// @dev Only callable by the royalty module or whitelisted royalty policy
    function addIpRoyaltyVaultTokens(address token) external {
        if (msg.sender != address(ROYALTY_MODULE) && !ROYALTY_MODULE.isWhitelistedRoyaltyPolicy(msg.sender))
            revert Errors.IpRoyaltyVault__NotAllowedToAddTokenToVault();

        _addIpRoyaltyVaultTokens(token);
    }

    /// @notice Snapshots the claimable revenue and royalty token amounts
    /// @return snapshotId The snapshot id
    function snapshot() external whenNotPaused returns (uint256) {
        IpRoyaltyVaultStorage storage $ = _getIpRoyaltyVaultStorage();

        if (block.timestamp - $.lastSnapshotTimestamp < IVaultController(address(ROYALTY_MODULE)).snapshotInterval())
            revert Errors.IpRoyaltyVault__InsufficientTimeElapsedSinceLastSnapshot();

        uint256 snapshotId = _snapshot();
        $.lastSnapshotTimestamp = uint40(block.timestamp);

        uint256 noRevenueCounter;
        address[] memory tokenList = $.tokens.values();
        for (uint256 i = 0; i < tokenList.length; i++) {
            uint256 tokenBalance = IERC20Upgradeable(tokenList[i]).balanceOf(address(this));
            if (tokenBalance == 0) {
                $.tokens.remove(tokenList[i]);
                continue;
            }

            uint256 newRevenue = tokenBalance - $.claimVaultAmount[tokenList[i]];
            if (newRevenue == 0) {
                noRevenueCounter++;
                continue;
            }

            $.claimableAtSnapshot[snapshotId][tokenList[i]] = newRevenue;
            $.claimVaultAmount[tokenList[i]] += newRevenue;
        }

        if (noRevenueCounter == tokenList.length) revert Errors.IpRoyaltyVault__NoNewRevenueSinceLastSnapshot();

        emit SnapshotCompleted(snapshotId, block.timestamp);

        return snapshotId;
    }

    /// @notice Calculates the amount of revenue token claimable by a token holder at certain snapshot
    /// @param account The address of the token holder
    /// @param snapshotId The snapshot id
    /// @param token The revenue token to claim
    /// @return The amount of revenue token claimable
    function claimableRevenue(
        address account,
        uint256 snapshotId,
        address token
    ) external view whenNotPaused returns (uint256) {
        return _claimableRevenue(account, snapshotId, token);
    }

    /// @notice Allows token holders to claim revenue token based on the token balance at certain snapshot
    /// @param snapshotId The snapshot id
    /// @param tokenList The list of revenue tokens to claim
    function claimRevenueByTokenBatch(
        uint256 snapshotId,
        address[] calldata tokenList
    ) external nonReentrant whenNotPaused {
        IpRoyaltyVaultStorage storage $ = _getIpRoyaltyVaultStorage();

        for (uint256 i = 0; i < tokenList.length; i++) {
            uint256 claimableToken = _claimableRevenue(msg.sender, snapshotId, tokenList[i]);
            if (claimableToken == 0) revert Errors.IpRoyaltyVault__NoClaimableTokens();

            $.isClaimedAtSnapshot[snapshotId][msg.sender][tokenList[i]] = true;
            $.claimVaultAmount[tokenList[i]] -= claimableToken;
            IERC20Upgradeable(tokenList[i]).safeTransfer(msg.sender, claimableToken);

            emit RevenueTokenClaimed(msg.sender, tokenList[i], claimableToken);
        }
    }

    /// @notice Allows token holders to claim by a list of snapshot ids based on the token balance at certain snapshot
    /// @param snapshotIds The list of snapshot ids
    /// @param token The revenue token to claim
    /// @return The amount of revenue tokens claimed
    function claimRevenueBySnapshotBatch(
        uint256[] memory snapshotIds,
        address token
    ) external nonReentrant whenNotPaused returns (uint256) {
        IpRoyaltyVaultStorage storage $ = _getIpRoyaltyVaultStorage();

        uint256 claimableToken;
        for (uint256 i = 0; i < snapshotIds.length; i++) {
            claimableToken += _claimableRevenue(msg.sender, snapshotIds[i], token);
            $.isClaimedAtSnapshot[snapshotIds[i]][msg.sender][token] = true;
        }

        if (claimableToken == 0) revert Errors.IpRoyaltyVault__NoClaimableTokens();

        $.claimVaultAmount[token] -= claimableToken;
        IERC20Upgradeable(token).safeTransfer(msg.sender, claimableToken);

        emit RevenueTokenClaimed(msg.sender, token, claimableToken);

        return claimableToken;
    }

    /// @notice Allows to claim revenue tokens on behalf of the ip royalty vault by token batch
    /// @param snapshotId The snapshot id
    /// @param tokenList The list of revenue tokens to claim
    /// @param targetIpId The target ip id to claim revenue tokens from
    function claimByTokenBatchAsSelf(
        uint256 snapshotId,
        address[] calldata tokenList,
        address targetIpId
    ) external whenNotPaused {
        address targetIpVault = ROYALTY_MODULE.ipRoyaltyVaults(targetIpId);
        if (targetIpVault == address(0)) revert Errors.IpRoyaltyVault__InvalidTargetIpId();

        IIpRoyaltyVault(targetIpVault).claimRevenueByTokenBatch(snapshotId, tokenList);

        // only tokens that have claimable revenue higher than zero will be added to the vault
        for (uint256 i = 0; i < tokenList.length; i++) {
            _addIpRoyaltyVaultTokens(tokenList[i]);
        }
    }

    /// @notice Allows to claim revenue tokens on behalf of the ip royalty vault by snapshot batch
    /// @param snapshotIds The list of snapshot ids
    /// @param token The revenue token to claim
    /// @param targetIpId The target ip id to claim revenue tokens from
    function claimBySnapshotBatchAsSelf(
        uint256[] memory snapshotIds,
        address token,
        address targetIpId
    ) external whenNotPaused {
        address targetIpVault = ROYALTY_MODULE.ipRoyaltyVaults(targetIpId);
        if (targetIpVault == address(0)) revert Errors.IpRoyaltyVault__InvalidTargetIpId();

        IIpRoyaltyVault(targetIpVault).claimRevenueBySnapshotBatch(snapshotIds, token);

        // the token will be added to the vault only if claimable revenue is higher than zero
        _addIpRoyaltyVaultTokens(token);
    }

    /// @notice Returns the current snapshot id
    /// @return The snapshot id
    function getCurrentSnapshotId() external view returns (uint256) {
        return _getCurrentSnapshotId();
    }

    /// @notice The ip id to whom this royalty vault belongs to
    function ipId() external view returns (address) {
        return _getIpRoyaltyVaultStorage().ipId;
    }

    /// @notice The last snapshotted timestamp
    function lastSnapshotTimestamp() external view returns (uint256) {
        return _getIpRoyaltyVaultStorage().lastSnapshotTimestamp;
    }

    /// @notice Amount of revenue token in the claim vault
    /// @param token The address of the revenue token
    function claimVaultAmount(address token) external view returns (uint256) {
        return _getIpRoyaltyVaultStorage().claimVaultAmount[token];
    }

    /// @notice Amount of revenue token claimable at a given snapshot
    /// @param snapshotId The snapshot id
    /// @param token The address of the revenue token
    function claimableAtSnapshot(uint256 snapshotId, address token) external view returns (uint256) {
        return _getIpRoyaltyVaultStorage().claimableAtSnapshot[snapshotId][token];
    }

    /// @notice Indicates whether the claimer has claimed the revenue tokens at a given snapshot
    /// @param snapshotId The snapshot id
    /// @param claimer The address of the claimer
    /// @param token The address of the revenue token
    function isClaimedAtSnapshot(uint256 snapshotId, address claimer, address token) external view returns (bool) {
        return _getIpRoyaltyVaultStorage().isClaimedAtSnapshot[snapshotId][claimer][token];
    }

    /// @notice Returns list of revenue tokens in the vault
    function tokens() external view returns (address[] memory) {
        return (_getIpRoyaltyVaultStorage().tokens).values();
    }

    /// @notice A function to calculate the amount of revenue token claimable by a token holder at certain snapshot
    /// @param account The address of the token holder
    /// @param snapshotId The snapshot id
    /// @param token The revenue token to claim
    /// @return The amount of revenue token claimable
    function _claimableRevenue(address account, uint256 snapshotId, address token) internal view returns (uint256) {
        IpRoyaltyVaultStorage storage $ = _getIpRoyaltyVaultStorage();

        // if the ip is tagged, then the unclaimed royalties are lost
        if (DISPUTE_MODULE.isIpTagged($.ipId)) return 0;

        uint256 balance = balanceOfAt(account, snapshotId);
        uint256 totalSupply = totalSupplyAt(snapshotId);
        uint256 claimableToken = $.claimableAtSnapshot[snapshotId][token];
        return $.isClaimedAtSnapshot[snapshotId][account][token] ? 0 : (balance * claimableToken) / totalSupply;
    }

    /// @notice Adds a new revenue token to the vault
    /// @param token The address of the revenue token
    function _addIpRoyaltyVaultTokens(address token) internal {
        if (!ROYALTY_MODULE.isWhitelistedRoyaltyToken(token))
            revert Errors.IpRoyaltyVault__NotWhitelistedRoyaltyToken();
        bool newTokenInVault = _getIpRoyaltyVaultStorage().tokens.add(token);
        if (newTokenInVault) emit RevenueTokenAddedToVault(token, address(this));
    }

    /// @dev Returns the storage struct of IpRoyaltyVault
    function _getIpRoyaltyVaultStorage() private pure returns (IpRoyaltyVaultStorage storage $) {
        assembly {
            $.slot := IpRoyaltyVaultStorageLocation
        }
    }
}
