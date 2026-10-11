// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { IUnlockCallback } from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import { FullMath } from "@uniswap/v4-core/src/libraries/FullMath.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { BalanceDelta } from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { ModifyLiquidityParams, SwapParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";
import { DecayingVolumeFeeHookV1 } from "./DecayingVolumeFeeHookV1.sol";
import { NativeLaunchTokenV1 } from "./NativeLaunchTokenV1.sol";

/// @notice One-shot, graph-factory-only native-ETH launch initializer, modelled on Programmable's native20 template:
///         registers + initializes the ETH/token pool through the fee hook, seeds the whole token inventory it was
///         minted as ONE single-sided Uniswap v4 position directly below the opening price, then (optionally)
///         executes a first buy with the exact native value forwarded by the Router, all in the launch transaction.
/// @dev The position is permanently owned by this contract. There is deliberately no remove / collect / approve /
///      operator / sweep / arbitrary-execution entry point, so the seeded principal can never leave the pool.
///      It seeds actual v4 concentrated liquidity with token inventory, not synthetic reserves.
contract NativeSeededLaunchInitializerV1 is IUnlockCallback {
    address public constant CANONICAL_POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address public constant CANONICAL_GRAPH_FACTORY = 0xB012e4A8F2c5FC4E8E4faCA9D5Ad6FfF13FBA887;
    bytes32 public constant POSITION_SALT = bytes32(0);

    IPoolManager public immutable poolManager;
    address public immutable graphFactory;
    uint24 public immutable lpFeePips;
    int24 public immutable tickSpacing;
    /// @notice Lower bound of the seeded range (token side).
    int24 public immutable tickLower;
    /// @notice Upper bound of the seeded range; the pool opens exactly at this tick, so the range is 100% token.
    int24 public immutable tickUpper;

    bool public initialized;
    address public token;
    address public hook;
    bytes32 public poolId;
    uint128 public lockedLiquidity;
    uint256 public seededTokenAmount;
    address public initialBuyer;
    uint256 public initialBuyWei;
    uint256 public initialTokensOut;
    uint256 public minimumInitialTokensOut;
    bytes32 private pendingUnlock;

    error InvalidEnvironment();
    error InvalidRange(int24 tickLower, int24 tickUpper, int24 tickSpacing);
    error UnauthorizedFactory();
    error AlreadyInitialized();
    error InvalidInventory();
    error InvalidHookBinding();
    error InvalidUnlock();
    error UnexpectedLiquidityDelta();
    error TokenSettlementMismatch();
    error InvalidInitialBuy();

    event TokenInventorySeeded(
        address indexed token,
        address indexed hook,
        bytes32 indexed poolId,
        int24 tickLower,
        int24 tickUpper,
        uint128 lockedLiquidity,
        uint256 tokenAmount
    );
    event InitialBuyExecuted(address indexed buyer, address indexed token, uint256 grossNativeWei, uint256 tokensOut);

    constructor(
        IPoolManager manager,
        address factory,
        uint24 lpFeePips_,
        int24 tickSpacing_,
        int24 tickLower_,
        int24 tickUpper_
    ) {
        if (
            block.chainid != 1 || address(manager) != CANONICAL_POOL_MANAGER || address(manager).code.length == 0
                || factory != CANONICAL_GRAPH_FACTORY
        ) revert InvalidEnvironment();
        if (
            tickSpacing_ < TickMath.MIN_TICK_SPACING || tickSpacing_ > TickMath.MAX_TICK_SPACING
                || tickLower_ >= tickUpper_ || tickLower_ % tickSpacing_ != 0 || tickUpper_ % tickSpacing_ != 0
                || tickLower_ < TickMath.minUsableTick(tickSpacing_) || tickUpper_ > TickMath.maxUsableTick(tickSpacing_)
        ) revert InvalidRange(tickLower_, tickUpper_, tickSpacing_);
        poolManager = manager;
        graphFactory = factory;
        lpFeePips = lpFeePips_;
        tickSpacing = tickSpacing_;
        tickLower = tickLower_;
        tickUpper = tickUpper_;
    }

    /// @notice Opening sqrt price: exactly the upper tick of the seeded range (quote ETH is currency0, token is currency1).
    function initialSqrtPriceX96() public view returns (uint160) {
        return TickMath.getSqrtPriceAtTick(tickUpper);
    }

    /// @notice Called only by the graph factory, after it deployed initializer, token and hook in the same transaction.
    /// @dev Deferred initialization avoids a CREATE2 constructor-reference cycle between initializer, token and hook.
    ///      `msg.value` (the Router's `initializerValueWei`) is spent in full as an exact-input first buy for `buyer_`;
    ///      pass 0 to skip the buy. The hook charges its launch-time fee on that buy like on any other swap.
    function initialize(
        address token_,
        address hook_,
        address projectFeeOwner_,
        address buyer_,
        uint256 minimumTokensOut_,
        DecayingVolumeFeeHookV1.FeeSchedule calldata buyFeeSchedule_,
        DecayingVolumeFeeHookV1.FeeSchedule calldata sellFeeSchedule_
    ) external payable {
        if (msg.sender != graphFactory) revert UnauthorizedFactory();
        if (initialized) revert AlreadyInitialized();
        if (msg.value != 0 && (buyer_ == address(0) || buyer_ == address(this) || minimumTokensOut_ == 0)) {
            revert InvalidInitialBuy();
        }
        if (msg.value > uint256(uint128(type(int128).max))) revert InvalidInitialBuy();
        if (token_.codehash != keccak256(type(NativeLaunchTokenV1).runtimeCode)) revert InvalidInventory();
        uint256 inventory = NativeLaunchTokenV1(token_).balanceOf(address(this));
        if (inventory == 0) revert InvalidInventory();
        DecayingVolumeFeeHookV1 feeHook = DecayingVolumeFeeHookV1(hook_);
        if (
            address(feeHook.poolManager()) != address(poolManager) || feeHook.registrar() != address(this)
                || feeHook.quoteCurrencyAddress() != address(0)
        ) revert InvalidHookBinding();

        uint160 sqrtUpper = initialSqrtPriceX96();
        uint256 liquidity = FullMath.mulDiv(inventory, 1 << 96, uint256(sqrtUpper) - TickMath.getSqrtPriceAtTick(tickLower));
        if (liquidity == 0 || liquidity > uint128(type(int128).max)) revert InvalidInventory();

        initialized = true;
        token = token_;
        hook = hook_;
        lockedLiquidity = uint128(liquidity);
        initialBuyer = buyer_;
        initialBuyWei = msg.value;
        minimumInitialTokensOut = minimumTokensOut_;

        // The hook owns pool registration: it validates the key, stores the fee schedules and calls PoolManager.initialize.
        (bytes32 registeredPoolId,) =
            feeHook.registerCanonicalPool(_poolKey(), projectFeeOwner_, buyFeeSchedule_, sellFeeSchedule_, sqrtUpper);
        poolId = registeredPoolId;

        bytes memory data = abi.encode(token_, hook_, lockedLiquidity, buyer_, msg.value, minimumTokensOut_);
        pendingUnlock = keccak256(data);
        bytes memory result = poolManager.unlock(data);
        if (
            pendingUnlock != bytes32(0) || result.length != 0 || seededTokenAmount == 0
                || (msg.value != 0 && initialTokensOut < minimumTokensOut_)
        ) revert InvalidUnlock();
        emit TokenInventorySeeded(token_, hook_, registeredPoolId, tickLower, tickUpper, lockedLiquidity, seededTokenAmount);
        if (msg.value != 0) emit InitialBuyExecuted(buyer_, token_, msg.value, initialTokensOut);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert InvalidUnlock();
        if (pendingUnlock == bytes32(0) || keccak256(data) != pendingUnlock) revert InvalidUnlock();
        pendingUnlock = bytes32(0);

        PoolKey memory key = _poolKey();
        (BalanceDelta delta, BalanceDelta feesAccrued) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(uint256(lockedLiquidity)),
                salt: POSITION_SALT
            }),
            ""
        );
        if (delta.amount0() != 0 || delta.amount1() >= 0 || BalanceDelta.unwrap(feesAccrued) != 0) {
            revert UnexpectedLiquidityDelta();
        }
        uint256 owed = uint256(-int256(delta.amount1()));
        seededTokenAmount = owed;
        poolManager.sync(Currency.wrap(token));
        if (!NativeLaunchTokenV1(token).transfer(address(poolManager), owed)) revert TokenSettlementMismatch();
        if (poolManager.settle() != owed) revert TokenSettlementMismatch();

        if (initialBuyWei == 0) return "";
        BalanceDelta buy = poolManager.swap(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(initialBuyWei),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            ""
        );
        if (int256(buy.amount0()) != -int256(initialBuyWei) || buy.amount1() <= 0) revert InvalidInitialBuy();
        uint256 tokensOut = uint256(int256(buy.amount1()));
        if (tokensOut < minimumInitialTokensOut) revert InvalidInitialBuy();
        initialTokensOut = tokensOut;
        poolManager.sync(Currency.wrap(address(0)));
        if (poolManager.settle{ value: initialBuyWei }() != initialBuyWei) revert InvalidInitialBuy();
        poolManager.take(Currency.wrap(token), initialBuyer, tokensOut);
        return "";
    }

    function _poolKey() private view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token),
            fee: lpFeePips,
            tickSpacing: tickSpacing,
            hooks: IHooks(hook)
        });
    }
}
