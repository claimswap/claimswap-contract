pragma solidity ^0.8.10;

import {LibAppStorage, AppStorage} from "../libraries/LibAppStorage.sol";

contract LpTokenFacet {
    event Transfer(address indexed from, address indexed to, uint256 value);

    event Approval(
        address indexed owner,
        address indexed spender,
        uint256 value
    );
    function totalSupply() external view returns (uint256) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        return s.totalSupply;
    }

    function balanceOf(address account)
        external 
        view
        returns (uint256)
    {
        AppStorage storage s = LibAppStorage.diamondStorage();
        return s.balances[account];
    }

    function allowance(address holder, address spender)
        external
        view
        returns (uint256)
    {
        
        AppStorage storage s = LibAppStorage.diamondStorage();
        return s.allowances[holder][spender];
    }

    function approve(address spender, uint256 amount)
        external
        returns (bool)
    {   
        _approve(msg.sender, spender, amount);
        return true;
    }

    function transfer(address recipient, uint256 amount)
        external
        returns (bool)
    {   
        _transfer(msg.sender, recipient, amount);
        return true;
    }

    function transferFrom(
        address holder,
        address recipient,
        uint256 amount
    ) external returns (bool) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        uint256 currentAllowance = s.allowances[holder][msg.sender];
        require(
            currentAllowance >= amount,
            'ERC20: transfer amount exceeds allowance'
        );
        unchecked {
            _approve(holder, msg.sender, currentAllowance - amount);
        }
        _transfer(holder, recipient, amount);
        return true;
    }

    /// FUNCTION FOR METADATA

    function name() external view returns (string memory) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        return s.name;
    }

    function symbol() external view returns (string memory) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        return s.symbol;
    }

    function decimals() external view returns (uint8) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        return s.decimals;
    }

    // INTERNAl

    function _approve(address holder, address spender, uint256 amount)
        internal
    {
        require(holder != address(0), 'ERC20: approve from the zero address');
        require(spender != address(0), 'ERC20: approve to the zero address');
        AppStorage storage s = LibAppStorage.diamondStorage();
        s.allowances[holder][spender] = amount;
        emit Approval(holder, spender, amount);
    }

    function _transfer(address sender, address recipient, uint256 amount)
        internal
    {
        require(sender != address(0), 'ERC20: transfer from the zero address');
        require(recipient != address(0), 'ERC20: transfer to the zero address');

        _beforeTokenTransfer(sender, recipient, amount);

        AppStorage storage s = LibAppStorage.diamondStorage();
        uint256 holderBalance = s.balances[sender];
        require(
            holderBalance >= amount,
            'ERC20: transfer amount exceeds balance'
        );
        unchecked {
            s.balances[sender] = holderBalance - amount;
        }
        s.balances[recipient] += amount;

        emit Transfer(sender, recipient, amount);
    }

    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal {
        AppStorage storage s = LibAppStorage.diamondStorage();
        require(!s.transferPaused, 'ERC20: transfer paused');
    }
}