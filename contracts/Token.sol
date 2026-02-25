pragma solidity 0.7.0;

import "./IERC20.sol";
import "./IMintableToken.sol";
import "./IDividends.sol";
import "./SafeMath.sol";

contract Token is IERC20, IMintableToken, IDividends {
  // ------------------------------------------ //
  // ----- BEGIN: DO NOT EDIT THIS SECTION ---- //
  // ------------------------------------------ //
  using SafeMath for uint256;
  uint256 public totalSupply;
  uint256 public decimals = 18;
  string public name = "Test token";
  string public symbol = "TEST";
  mapping (address => uint256) public balanceOf;
  // ------------------------------------------ //
  // ----- END: DO NOT EDIT THIS SECTION ------ //  
  // ------------------------------------------ //



  // Allowances for ERC-20 delegated transfers
  mapping (address => mapping (address => uint256)) private _allowance;

  // holders list (addresses with non-zero balance)

  // List of all addresses with non-zero balance
  address[] private holders;
  // 1-based index for each holder in the array (0 means not present)
  mapping(address => uint256) private holderIndex;

  // dividends
  // Used for fixed-point math in dividend calculations
  uint256 private constant MAG = 10**18;
  // Accumulated dividend per token (scaled by MAG)
  uint256 private dividendPerToken;
  // Last dividendPerToken seen by each account
  mapping(address => uint256) private lastDividendPerToken;
  // Amount of dividend owed to each account (accumulated)
  mapping(address => uint256) private owed;


  // IERC20

  // Returns how much 'spender' is allowed to transfer from 'owner'
  function allowance(address owner, address spender) external view override returns (uint256) {
    return _allowance[owner][spender];
  }

  // Standard ERC-20 transfer: move tokens from sender to recipient
  function transfer(address to, uint256 value) external override returns (bool) {
    address from = msg.sender;
    require(balanceOf[from] >= value, "insufficient balance");

    if (value == 0) {
      return true;
    }

    // Settle dividends for both parties before changing balances
    _updateAccount(from);
    _updateAccount(to);

    balanceOf[from] = balanceOf[from].sub(value);
    if (balanceOf[from] == 0) _removeHolder(from); // Remove if balance hits zero

    bool wasZero = balanceOf[to] == 0;
    balanceOf[to] = balanceOf[to].add(value);
    if (wasZero && balanceOf[to] > 0) _addHolder(to); // Add if new holder

    return true;
  }

  // Approve 'spender' to transfer up to 'value' tokens from sender
  function approve(address spender, uint256 value) external override returns (bool) {
    _allowance[msg.sender][spender] = value;
    return true;
  }

  // ERC-20 delegated transfer: move tokens from 'from' to 'to' if allowed
  function transferFrom(address from, address to, uint256 value) external override returns (bool) {
    address sender = msg.sender;
    require(_allowance[from][sender] >= value, "allowance exceeded");
    require(balanceOf[from] >= value, "insufficient balance");

    if (value == 0) {
      return true;
    }

    // Settle dividends for both parties before changing balances
    _updateAccount(from);
    _updateAccount(to);

    _allowance[from][sender] = _allowance[from][sender].sub(value);

    balanceOf[from] = balanceOf[from].sub(value);
    if (balanceOf[from] == 0) _removeHolder(from);

    bool wasZero = balanceOf[to] == 0;
    balanceOf[to] = balanceOf[to].add(value);
    if (wasZero && balanceOf[to] > 0) _addHolder(to);

    return true;
  }

  // IMintableToken

  // Mint tokens by sending ETH; 1 token per wei
  function mint() external payable override {
    require(msg.value > 0, "no ETH sent");

    address acct = msg.sender;

    // Settle dividends before changing balance
    _updateAccount(acct);

    bool wasZero = balanceOf[acct] == 0;
    balanceOf[acct] = balanceOf[acct].add(msg.value);
    totalSupply = totalSupply.add(msg.value);

    if (wasZero && balanceOf[acct] > 0) _addHolder(acct);
  }

  // Burn all tokens held by sender and send equivalent ETH to 'dest'
  function burn(address payable dest) external override {
    address acct = msg.sender;
    uint256 bal = balanceOf[acct];
    require(bal > 0, "no balance to burn");

    // Settle dividends before changing balance
    _updateAccount(acct);

    balanceOf[acct] = 0;
    totalSupply = totalSupply.sub(bal);
    _removeHolder(acct);

    // Send ETH back to user
    dest.transfer(bal);
  }

  // IDividends

  // Returns the number of addresses with non-zero balance
  function getNumTokenHolders() external view override returns (uint256) {
    return holders.length;
  }

  // Returns the address of the Nth holder (1-based index)
  function getTokenHolder(uint256 index) external view override returns (address) {
    if (index == 0 || index > holders.length) return address(0);
    return holders[index - 1];
  }

  // Assign a new dividend to all current token holders (proportional)
  function recordDividend() external payable override {
    require(msg.value > 0, "no ETH sent");
    require(totalSupply > 0, "no supply");

    // Increase the per-token dividend accumulator
    dividendPerToken = dividendPerToken.add(msg.value.mul(MAG).div(totalSupply));
  }

  // Returns the dividend currently withdrawable by 'payee'
  function getWithdrawableDividend(address payee) external view override returns (uint256) {
    uint256 pending = 0;
    uint256 lpt = lastDividendPerToken[payee];
    if (dividendPerToken > lpt) {
      // Calculate any new dividend since last update
      pending = balanceOf[payee].mul(dividendPerToken.sub(lpt)).div(MAG);
    }
    return owed[payee].add(pending);
  }

  // Withdraw all accumulated dividend for sender to 'dest'
  function withdrawDividend(address payable dest) external override {
    address acct = msg.sender;
    // Settle any pending dividend
    _updateAccount(acct);

    uint256 amount = owed[acct];
    require(amount > 0, "no dividend to withdraw");

    owed[acct] = 0;
    // Update last seen dividend pointer
    lastDividendPerToken[acct] = dividendPerToken;

    dest.transfer(amount);
  }

  // internal helpers
  // Add address to holders list if not already present
  function _addHolder(address a) internal {
    if (a == address(0)) return;
    if (holderIndex[a] != 0) return;
    holders.push(a);
    holderIndex[a] = holders.length; // 1-based
    // New holders start with current dividend snapshot
    lastDividendPerToken[a] = dividendPerToken;
  }

  // Remove address from holders list (swap and pop)
  function _removeHolder(address a) internal {
    if (a == address(0)) return;
    uint256 idx = holderIndex[a];
    if (idx == 0) return;

    uint256 i = idx - 1;
    uint256 last = holders.length - 1;
    if (i != last) {
      address swapped = holders[last];
      holders[i] = swapped;
      holderIndex[swapped] = i + 1;
    }
    holders.pop();
    holderIndex[a] = 0;
  }

  // Settle any new dividend for address 'a' and update owed/lastDividendPerToken
  function _updateAccount(address a) internal {
    if (a == address(0)) return;
    uint256 lpt = lastDividendPerToken[a];
    if (dividendPerToken > lpt) {
      uint256 delta = dividendPerToken.sub(lpt);
      uint256 add = balanceOf[a].mul(delta).div(MAG);
      if (add > 0) owed[a] = owed[a].add(add);
      lastDividendPerToken[a] = dividendPerToken;
    }
  }
}
