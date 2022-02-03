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
    mapping(address => uint) internal converted;

    event SetDevAddr(address _addr);
    event SetDevCut(uint _amount);
    event LogBridgeSet(address indexed token, address indexed bridge);
    event LogConvert(
        address indexed server,
        address indexed token0,
        uint256 amount0,
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

    // setting anyAuth to true allows anyone to call functions protected by onlyAuth permanently
    function setAnyAuth() external onlyOwner {
        anyAuth = true;
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

    function isLpToken(address _adr) internal view returns (bool) {
        IUniswapV2Pair pair = IUniswapV2Pair(_adr);
        try pair.factory() {
            return true;
        } catch {
            return false;
        }
    }

    // F1 - F10: OK, see convert
    // C1 - C24: OK
    // C3: Loop is under control of the caller
    function convertMultiple(
        address[] calldata token0,
        address[] calldata token1
    ) external onlyEOA() onlyAuth() {

        uint len = token0.length;
        uint i;
        for (i = 0; i < len; i++) {
            if (token0[i] == token1[i])
                require(!isLpToken(token0[i], "no LP allowed");
                continue;
            require(!isLpToken(token0[i], "no LP allowed");
            require(!isLpToken(token1[i], "no LP allowed");
            IUniswapV2Pair pair = IUniswapV2Pair(factory.getPair(token0[i], token1[i]));
            require(address(pair) != address(0), "BrewBoo: Invalid pair");

            IERC20(address(pair)).safeTransfer(address(pair), pair.balanceOf(address(this)));
            pair.burn(address(this));
        }
        converted[wftm] = block.number;
        for (i = 0; i < len; i++) {
            if(block.number > converted[token0[i]]) {
                _convertStep(token0[i], IERC20(token0[i]).balanceOf(address(this)));
                converted[token0[i]] = block.number;
            }
            if(block.number > converted[token1[i]]) {
                _convertStep(token1[i], IERC20(token1[i]).balanceOf(address(this)));
                converted[token1[i]] = block.number;
            }
        }

        uint wftmBal = IERC20(wftm).balanceOf(address(this));
        uint amount = _toBOO(wftm, wftmBal);
        emit LogConvert(msg.sender, wftm, wftmBal, amount);
    }

    // F1 - F10: OK
    // C1 - C24: OK
    // All safeTransfer, _swap, _toBOO, _convertStep: X1 - X5: OK
    function _convertStep(
        address token0,
        uint256 amount0
    ) internal returns (bool) {
        // Interactions
        uint256 amount = amount0;
        if (token0 == boo) {
            IERC20(boo).safeTransfer(xboo, amount);
            emit LogConvert(msg.sender, token0, amount0, amount);
        } else if (token0 == wftm) {
            return true;
        } else {
            address bridge = bridgeFor(token0);
            amount = _swap(token0, bridge, amount, address(this));
            _convertStep(bridge, amount);
        }
        return true;
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
