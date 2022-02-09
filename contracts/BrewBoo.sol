// SPDX-License-Identifier: MIT

// P1 - P3: OK
pragma solidity 0.6.12;

import '@openzeppelin/contracts/token/ERC20/SafeERC20.sol';
import '@openzeppelin/contracts/math/SafeMath.sol';
import '@openzeppelin/contracts/access/Ownable.sol';
import "./interfaces/IUniswapV2ERC20.sol";
import "./interfaces/IUniswapV2Pair.sol";
import "./interfaces/IUniswapV2Factory.sol";

// BrewBoo is MasterChef's left hand and kinda a wizard. He can brew Boo from pretty much anything!
// This contract handles "serving up" rewards for xBoo holders by trading tokens collected from fees for Boo.

// T1 - T4: OK
contract BrewBoo is Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    IUniswapV2Factory public immutable factory;

    address public immutable xboo;
    address private immutable boo;
    address private immutable wftm;
    uint public devCut = 0;  // in basis points aka parts per 10,000 so 5000 is 50%, cap of 50%, default is 0
    address public devAddr;

    // set of addresses that can perform certain functions
    mapping(address => bool) public isAuth;
    address[] public authorized;
    bool public anyAuth = false;

    modifier onlyAuth() {
        require(isAuth[msg.sender] || anyAuth, "BrewBoo: FORBIDDEN");
        _;
    }

    // V1 - V5: OK
    mapping(address => address) internal _bridges;

    event SetDevAddr(address _addr);
    event SetDevCut(uint _amount);
    event LogBridgeSet(address indexed token, address indexed bridge);
    event LogConvert(
        address indexed server,
        address indexed token0,
        address indexed token1,
        uint256 amount0,
        uint256 amount1,
        uint256 amountBOO
    );

    constructor(
        address _factory,
        address _xboo,
        address _boo,
        address _wftm
    ) public {
        factory = IUniswapV2Factory(_factory);
        xboo = _xboo;
        boo = _boo;
        wftm = _wftm;
        devAddr = msg.sender;
        isAuth[msg.sender] = true;
        authorized.push(msg.sender);
    }
    // Begin Owner functions
    function addAuth(address _auth) external onlyOwner {
        isAuth[_auth] = true;
        authorized.push(_auth);
    }

    function revokeAuth(address _auth) external onlyOwner {
        isAuth[_auth] = false;
    }

    // setting anyAuth to true allows anyone to call functions protected by onlyAuth
    function setAnyAuth(bool access) external onlyOwner {
        anyAuth = access;
    }

    function setBridge(address token, address bridge) external onlyOwner {
        // Checks
        require(
            token != boo && token != wftm && token != bridge,
            "BrewBoo: Invalid bridge"
        );

        // Effects
        _bridges[token] = bridge;
        emit LogBridgeSet(token, bridge);
    }

    function setDevCut(uint _amount) external onlyOwner {
        require(_amount <= 5000, "setDevCut: cut too high");
        devCut = _amount;
        
        emit SetDevCut(_amount);
    }

    function setDevAddr(address _addr) external onlyOwner {
        require(_addr != address(0), "setDevAddr, address cannot be zero address");
        devAddr = _addr;

        emit SetDevAddr(_addr);
    }
    // End owner functions

    function bridgeFor(address token) public view returns (address bridge) {
        bridge = _bridges[token];
        if (bridge == address(0)) {
            bridge = wftm;
        }
    }

    // C6: It's not a fool proof solution, but it prevents flash loans, so here it's ok to use tx.origin
    modifier onlyEOA() {
        // Try to make flash-loan exploit harder to do by only allowing externally owned addresses.
        require(msg.sender == tx.origin, "BrewBoo: must use EOA");
        _;
    }

    // F1 - F10: OK
    // F3: _convert is separate to save gas by only checking the 'onlyEOA' modifier once in case of convertMultiple
    // F6: There is an exploit to add lots of BOO to the xboo, run convert, then remove the BOO again.
    //     As the size of the Booxboo has grown, this requires large amounts of funds and isn't super profitable anymore
    //     The onlyEOA modifier prevents this being done with a flash loan.
    // C1 - C24: OK
    function convert(address token0, address token1) external onlyEOA() onlyAuth() {
        _convert(token0, token1);
    }

    // F1 - F10: OK, see convert
    // C1 - C24: OK
    // C3: Loop is under control of the caller
    function convertMultiple(
        address[] calldata token0,
        address[] calldata token1
    ) external onlyEOA() onlyAuth() {
        // TODO: This can be optimized a fair bit, but this is safer and simpler for now
        uint256 len = token0.length;
        for (uint256 i = 0; i < len; i++) {
            _convert(token0[i], token1[i]);
        }
    }

    // F1 - F10: OK
    // C1- C24: OK
    function _convert(address token0, address token1) internal {
        uint256 amount0;
        uint256 amount1;

        // handle case where non-LP tokens need to be converted
        if(token0 == token1) {
            amount0 = IERC20(token0).balanceOf(address(this));
            amount1 = 0;
        }
        else {

            IUniswapV2Pair pair = IUniswapV2Pair(factory.getPair(token0, token1));
            require(address(pair) != address(0), "BrewBoo: Invalid pair");

            IERC20(address(pair)).safeTransfer(
                address(pair),
                pair.balanceOf(address(this))
            );

            // take balance of tokens in this contract before burning the pair, incase there are already some here
            uint tok0bal = IERC20(token0).balanceOf(address(this));
            uint tok1bal = IERC20(token1).balanceOf(address(this));

            pair.burn(address(this));

            // subtract old balance of tokens from new balance
            // the return values of pair.burn cant be trusted due to transfer tax tokens
            amount0 = IERC20(token0).balanceOf(address(this)).sub(tok0bal);
            amount1 = IERC20(token1).balanceOf(address(this)).sub(tok1bal);
            
        }
        emit LogConvert(
            msg.sender,
            token0,
            token1,
            amount0,
            amount1,
            _convertStep(token0, token1, amount0, amount1)
        );
    }

    // F1 - F10: OK
    // C1 - C24: OK
    // All safeTransfer, _swap, _toBOO, _convertStep: X1 - X5: OK
    function _convertStep(
        address token0,
        address token1,
        uint256 amount0,
        uint256 amount1
    ) internal returns (uint256 booOut) {
        // Interactions
        if (token0 == token1) {
            uint256 amount = amount0.add(amount1);
            if (token0 == boo) {
                IERC20(boo).safeTransfer(xboo, amount);
                booOut = amount;
            } else if (token0 == wftm) {
                booOut = _toBOO(wftm, amount);
            } else {
                address bridge = bridgeFor(token0);
                amount = _swap(token0, bridge, amount, address(this));
                booOut = _convertStep(bridge, bridge, amount, 0);
            }
        } else if (token0 == boo) {
            // eg. BOO - ETH
            IERC20(boo).safeTransfer(xboo, amount0);
            booOut = _toBOO(token1, amount1).add(amount0);
        } else if (token1 == boo) {
            // eg. USDT - BOO
            IERC20(boo).safeTransfer(xboo, amount1);
            booOut = _toBOO(token0, amount0).add(amount1);
        } else if (token0 == wftm) {
            // eg. ETH - USDC
            booOut = _toBOO(
                wftm,
                _swap(token1, wftm, amount1, address(this)).add(amount0)
            );
        } else if (token1 == wftm) {
            // eg. USDT - ETH
            booOut = _toBOO(
                wftm,
                _swap(token0, wftm, amount0, address(this)).add(amount1)
            );
        } else {
            // eg. MIC - USDT
            address bridge0 = bridgeFor(token0);
            address bridge1 = bridgeFor(token1);
            if (bridge0 == token1) {
                // eg. MIC - USDT - and bridgeFor(MIC) = USDT
                booOut = _convertStep(
                    bridge0,
                    token1,
                    _swap(token0, bridge0, amount0, address(this)),
                    amount1
                );
            } else if (bridge1 == token0) {
                // eg. WBTC - DSD - and bridgeFor(DSD) = WBTC
                booOut = _convertStep(
                    token0,
                    bridge1,
                    amount0,
                    _swap(token1, bridge1, amount1, address(this))
                );
            } else {
                booOut = _convertStep(
                    bridge0,
                    bridge1, // eg. USDT - DSD - and bridgeFor(DSD) = WBTC
                    _swap(token0, bridge0, amount0, address(this)),
                    _swap(token1, bridge1, amount1, address(this))
                );
            }
        }
    }

    // F1 - F10: OK
    // C1 - C24: OK
    // All safeTransfer, swap: X1 - X5: OK
    function _swap(
        address fromToken,
        address toToken,
        uint256 amountIn,
        address to
    ) internal returns (uint256 amountOut) {
        // Checks
        // X1 - X5: OK
        IUniswapV2Pair pair =
            IUniswapV2Pair(factory.getPair(fromToken, toToken));
        require(address(pair) != address(0), "BrewBoo: Cannot convert");

        (uint256 reserve0, uint256 reserve1, ) = pair.getReserves();
        (uint reserveInput, uint reserveOutput) = fromToken == pair.token0() ? (reserve0, reserve1) : (reserve1, reserve0);
        IERC20(fromToken).safeTransfer(address(pair), amountIn);
        uint amountInput = IERC20(fromToken).balanceOf(address(pair)).sub(reserveInput); // calculate amount that was transferred, this accounts for transfer taxes

        amountOut = getAmountOut(amountInput, reserveInput, reserveOutput);
        (uint amount0Out, uint amount1Out) = fromToken == pair.token0() ? (uint(0), amountOut) : (amountOut, uint(0));
        pair.swap(amount0Out, amount1Out, to, new bytes(0));        
    }

    // F1 - F10: OK
    // C1 - C24: OK
    function _toBOO(address token, uint256 amountIn)
        internal
        returns (uint256 amountOut)
    {   
        uint256 amount = amountIn;
        if (devCut > 0) {
            amount = amount.mul(devCut).div(10000);
            IERC20(token).safeTransfer(devAddr, amount);
            amount = amountIn.sub(amount);
        }
        amountOut = _swap(token, boo, amount, xboo);
    }

    function getAmountOut(uint amountIn, uint reserveIn, uint reserveOut) internal pure returns (uint amountOut) {
        require(amountIn > 0, 'BrewBoo: INSUFFICIENT_INPUT_AMOUNT');
        require(reserveIn > 0 && reserveOut > 0, 'BrewBoo: INSUFFICIENT_LIQUIDITY');
        uint amountInWithFee = amountIn.mul(998);
        uint numerator = amountInWithFee.mul(reserveOut);
        uint denominator = reserveIn.mul(1000).add(amountInWithFee);
        amountOut = numerator / denominator;
    }
}