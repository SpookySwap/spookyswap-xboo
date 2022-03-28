// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.10;

import '@openzeppelin/contracts/access/Ownable.sol';
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IUniswapV2Pair.sol";
import "./interfaces/ISwapper.sol";


contract Swapper is ISwapper, Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;


    uint public slippage = 9;
    mapping(address => bool) public slippageOverrode;


    // onlyAuth type functions

    function overrideSlippage(address _token) external onlyOwner {
        slippageOverrode[_token] = !slippageOverrode[_token];
    }

    function setSlippage(uint _amt) external onlyOwner {
        require(_amt < 20, "slippage setting too high"); // the higher this setting, the lower the slippage tolerance, too high and buybacks would never work
        slippage = _amt;
    }

    function swap(
        address fromToken,
        address _pair,
        uint256 amountIn
    ) external onlyOwner returns (uint256 amountOut) {
        IUniswapV2Pair pair = IUniswapV2Pair(_pair);
        require(address(pair) != address(0), "BrewBoo: Cannot convert");

        (uint256 reserve0, uint256 reserve1, ) = pair.getReserves();
        (uint reserveInput, uint reserveOutput) = fromToken == pair.token0() ? (reserve0, reserve1) : (reserve1, reserve0);
        
        IERC20(fromToken).safeTransferFrom(msg.sender, address(pair), amountIn);
        uint amountInput = IERC20(fromToken).balanceOf(address(pair)).sub(reserveInput); // calculate amount that was transferred, this accounts for transfer taxes
        require(slippageOverrode[fromToken] || reserveInput.div(amountInput) > slippage, "slippage too high");

        amountOut = _getAmountOut(amountInput, reserveInput, reserveOutput);
        (uint amount0Out, uint amount1Out) = fromToken == pair.token0() ? (uint(0), amountOut) : (amountOut, uint(0));
        pair.swap(amount0Out, amount1Out, msg.sender, new bytes(0));
    }

    function _getAmountOut(uint amountIn, uint reserveIn, uint reserveOut) internal pure returns (uint amountOut) {
        require(amountIn > 0, 'BrewBoo: INSUFFICIENT_INPUT_AMOUNT');
        require(reserveIn > 0 && reserveOut > 0, 'BrewBoo: INSUFFICIENT_LIQUIDITY');
        uint amountInWithFee = amountIn.mul(998);
        uint numerator = amountInWithFee.mul(reserveOut);
        uint denominator = reserveIn.mul(1000).add(amountInWithFee);
        amountOut = numerator / denominator;
    }
}
