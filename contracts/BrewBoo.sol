// SPDX-License-Identifier: MIT

// P1 - P3: OK
pragma solidity 0.8.10;

import '@openzeppelin/contracts/access/Ownable.sol';
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./interfaces/IUniswapV2Pair.sol";
import "./interfaces/IUniswapV2Factory.sol";
import "./Swapper.sol";

// BrewBoo is MasterChef's left hand and kinda a wizard. He can brew Boo from pretty much anything!
// This contract handles "serving up" rewards for xBoo holders by trading tokens collected from fees for Boo.
// The caller of convertMultiple, the function responsible for converting fees to BOO earns a 0.1% reward for calling.
contract BrewBooV3 is Ownable, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    IUniswapV2Factory public immutable factory;
    ISwapper public immutable swapper;

    address public immutable xboo;
    address private immutable boo;
    address private immutable wftm;
    uint public devCut;  // in basis points aka parts per 10,000 so 5000 is 50%, cap of 50%, default is 0
    uint public constant BOUNTY_FEE = 10;
    address public devAddr;
    //uint public slippage = 9;

    // set of addresses that can perform certain functions
    mapping(address => bool) public isAuth;
    address[] public authorized;
    bool public anyAuth = false;

    modifier onlyAuth() {
        require(isAuth[_msgSender()], "BrewBoo: FORBIDDEN");
        _;
    }

    // C6: It's not a fool proof solution, but it prevents flash loans, so here it's ok to use tx.origin
    modifier onlyEOA() {
        // Try to make flash-loan exploit harder to do by only allowing externally owned addresses.
        require(msg.sender == tx.origin, "BrewBoo: must use EOA");
        _;
    }

    mapping(address => uint) internal converted;
    mapping(address => bool) public overrode;
    mapping(address => bool) public swapperApproved;

    //token bridges to try in order when swapping, first three are immutably wftm, usdc, dai
    mapping(uint => address) public bridgeRoute;
    uint public bridgeRouteAmount = 3; // "array" size aka next free slot in the mapping
    mapping(address => address) public lastRoute; //tokens last succesful route, will be tried first

    event SetDevAddr(address _addr);
    event SetDevCut(uint _amount);
    event LogBridgeSet(address indexed token, address indexed bridge);
    event LogConvert(
        address indexed server,
        address indexed token0,
        uint256 amount0,
        uint256 amountBOO
    );
    event LogSetAnyAuth();
    event LogToggleOverrode(address _adr);
    event LogSlippageOverrode(address _adr);

    constructor(
        address _factory,
        address _xboo,
        address _boo,
        address _wftm
    ) {
        factory = IUniswapV2Factory(_factory);
        xboo = _xboo;
        boo = _boo;
        wftm = _wftm;
        devAddr = msg.sender;
        isAuth[msg.sender] = true;
        authorized.push(msg.sender);
        bridgeRoute[0] = _wftm;
        bridgeRoute[1] = 0x04068DA6C83AFCFA0e13ba15A6696662335D5B75;
        bridgeRoute[2] = 0x8D11eC38a3EB5E956B052f67Da8Bdc9bef8Abf3E;
        swapper = new Swapper();
    }

    function setBridgeRoute(uint index, address token) external onlyAuth {
        require(index > 2, "first 3 bridge tokens are immutable");
        require(index <= bridgeRouteAmount, "index too large, use next free slot");

        bridgeRoute[index] = token;
        if(index == bridgeRouteAmount)
            bridgeRouteAmount += 1;
    }

    function setBridgeRouteAmount(uint amount) external onlyAuth {
        require(amount > 2);
        bridgeRouteAmount = amount;
    }

    function isLpToken(address _adr) internal returns (bool) {
        if (overrode[_adr]) return false;
        IUniswapV2Pair pair = IUniswapV2Pair(_adr);
        try pair.token0() {
            address token0 = pair.token0();
            address token1 = pair.token1();
            address realPair = factory.getPair(token0, token1);
            // check if newly derived pair is the same as the address passed in
            if (_adr != realPair) {
                overrode[_adr] = true;
                emit LogToggleOverrode(_adr);
                return false;
            }
            return true;
        } catch {
            return false;
        }
    }

    // Begin Owner functions
    function addAuth(address _auth) external onlyOwner {
        isAuth[_auth] = true;
        authorized.push(_auth);
    }

    function revokeAuth(address _auth) external onlyOwner {
        isAuth[_auth] = false;
    }

    // setting anyAuth to true allows anyone to call convertMultiple permanently
    function setAnyAuth() external onlyOwner {
        anyAuth = true;
        emit LogSetAnyAuth();
    }

    function setDevCut(uint _amount) external onlyOwner {
        require(_amount <= 5000, "setDevCut: cut too high");
        devCut = _amount;

        emit SetDevCut(_amount);
    }

    function setDevAddr(address _addr) external {
        require(owner() == _msgSender() || devAddr == _msgSender(), "not allowed");
        require(_addr != address(0), "setDevAddr, address cannot be zero address");
        devAddr = _addr;

        emit SetDevAddr(_addr);
    }
    // End owner functions

    // onlyAuth type functions

    function overrideSlippage(address _token) external onlyAuth {
        swapper.overrideSlippage(_token);
        emit LogSlippageOverrode(_token);
    }

    function setSlippage(uint _amt) external onlyAuth {
        swapper.setSlippage(_amt);
    }

    function setBridge(address token, address bridge) external onlyAuth {
        // Checks
        require(
            token != boo && token != wftm && token != bridge,
            "BrewBoo: Invalid bridge"
        );

        // Effects
        lastRoute[token] = bridge;
        emit LogBridgeSet(token, bridge);
    }

    function convertMultiple(
        address[] calldata token0,
        address[] calldata token1
    ) external onlyEOA() nonReentrant() {
        require(anyAuth || isAuth[_msgSender()], "BrewBoo: FORBIDDEN");
        uint len = token0.length;
        uint i;
        for (i = 0; i < len;) {
            if (token0[i] == token1[i]) {
                require(!isLpToken(token0[i]), "no LP allowed");
                continue;
            }
            require(!isLpToken(token0[i]) && !isLpToken(token1[i]), "no LP allowed");
            IUniswapV2Pair pair = IUniswapV2Pair(factory.getPair(token0[i], token1[i]));
            require(address(pair) != address(0), "BrewBoo: Invalid pair");

            IERC20(address(pair)).safeTransfer(address(pair), pair.balanceOf(address(this)));
            pair.burn(address(this));
            unchecked {++i;}
        }

        converted[wftm] = block.number; // wftm is done last
        for (i = 0; i < len;) {
            if(block.number > converted[token0[i]]) {
                _convertStep(token0[i], IERC20(token0[i]).balanceOf(address(this)));
                converted[token0[i]] = block.number;
            }
            if(block.number > converted[token1[i]]) {
                _convertStep(token1[i], IERC20(token1[i]).balanceOf(address(this)));
                converted[token1[i]] = block.number;
            }
            unchecked {++i;}
        }
        // final step is to swap all wFTM to BOO and disperse it
        uint wftmBal = IERC20(wftm).balanceOf(address(this));
        _toBOO(wftm, wftmBal);
        _disperseBOO();
    }

    // internal functions

    function _convertStep(
        address token0,
        uint256 amount0
    ) internal returns (bool) {
        // Interactions
        uint256 amount = amount0;
        bool success = false;
        if (token0 == boo || token0 == wftm) {
            return true;
        } else {
            address bridge;
            bridge = lastRoute[token0];
            if(bridge != address(0))
                (amount, success) = _swap(token0, bridge, amount);

            if(success)
                _convertStep(bridge, amount);
            else for(uint i = 0; i < bridgeRouteAmount;) {
                bridge = bridgeRoute[i];
                if(bridge == address(0)) continue;
                (amount, success) = _swap(token0, bridge, amount);
                if(!success)
                    if(i == bridgeRouteAmount - 1)
                        revert("BrewBooV3: bridge route failure - all options exhausted");
                    else {
                        unchecked {++i;}
                        continue;
                    }
                lastRoute[token0] = bridge;
                _convertStep(bridge, amount);
                break;
            }

            //danger zone
        }
        return true;
    }

    function _disperseBOO() internal returns (uint amount){
        uint _amt = IERC20(boo).balanceOf(address(this));
        uint bounty = _amt.mul(BOUNTY_FEE).div(10000);
        amount = _amt.sub(bounty);
        IERC20(boo).safeTransfer(xboo, amount); // send xboo its share
        IERC20(boo).safeTransfer(_msgSender(), bounty); // send message sender their share of 0.1%
        emit LogConvert(_msgSender(), boo, _amt, amount);
    }

    function _swap(
        address fromToken,
        address toToken,
        uint256 amountIn
    ) internal returns (uint256 amountOut, bool success) {
        if(fromToken == toToken)
            return (amountIn, false);

        if(!swapperApproved[fromToken]) {
            IERC20(fromToken).approve(address(swapper), 2**256 - 1);
            swapperApproved[fromToken] = true;
        }

        try swapper.swap(fromToken, factory.getPair(fromToken, toToken), amountIn) returns (uint amount) {
            return (amount, true);
        } catch {
            return (amountIn, false);
        }
    }

    function _toBOO(address token, uint256 amountIn) internal returns (uint256 amountOut) {
        uint256 amount = amountIn;
        bool success;
        if (devCut > 0) {
            amount = amount.mul(devCut).div(10000);
            IERC20(token).safeTransfer(devAddr, amount);
            amount = amountIn.sub(amount);
        }
        (amountOut, success) = _swap(token, boo, amount);
        if(!success)
            revert("BrewBooV3: swap failure in toBOO");
    }
}
