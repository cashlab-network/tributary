// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "./interfaces/IERC20.sol";

interface ILoanVaultForAccount {
    function statusOf(uint256 id) external view returns (uint8);
    function borrowerOf(uint256 id) external view returns (address);
    function collectorOf(uint256 id) external view returns (address);
}

/// @title BorrowerAccount — Tributary's own claim-binding account (v2 core)
/// @notice The cure for v1's honest weakness: on a plain wallet, Flare's
///         contracts always let the owner self-claim around the vault. This
///         account replaces the plain wallet as the borrower's REWARD
///         IDENTITY: the borrower points reward flows at it and keeps full
///         control — right up until they bind it to a loan. While bound:
///           - value held or received here moves ONLY to the loan's
///             collector (routeToCollector, callable by anyone);
///           - the owner's general-purpose exec() works ONLY against a
///             target allowlist pinned at bind time — so no token transfers,
///             no approvals, no re-pointing of claim settings, unless that
///             exact contract was declared up front where the lender could
///             see it before funding;
///           - the binding releases itself the moment the vault reports the
///             loan terminal. No administrator, no override, no Flare
///             changes needed.
///
///         Debt DAO inheritances: the binding is scoped to one loan and
///         self-expiring (M-02 — no standing authorization); value routes
///         only to the registered collector, never an inferred destination
///         (H-02); the allowlist is immutable per binding — changing it
///         means closing the loan and binding anew.
contract BorrowerAccount {
    error NotOwner();
    error NotBound();
    error AlreadyBound(uint256 loanId);
    error LoanStillActive(uint256 loanId);
    error BindingForbidsThis();
    error NotThisAccountsLoan();
    error WrongCollector(address given, address actual);
    error CallFailed();

    event Bound(uint256 indexed loanId, address vault, address collector);
    event Released(uint256 indexed loanId);
    event RoutedToCollector(address indexed token, uint256 amount);
    event ApprovalRevoked(address indexed token, address indexed spender);

    struct Approval {
        address token;
        address spender;
    }
    /// Every ERC-20 approve() made through exec() is recorded here, so bind()
    /// can revoke them all — closing MEDIUM-2: a standing approval granted
    /// while unbound must not survive the fence and let an accomplice
    /// transferFrom a later WFLR reward out of the bound account.
    Approval[] internal grantedApprovals;

    address public immutable owner;

    ILoanVaultForAccount public vault; // set while bound
    address public collector; // the ONLY value destination while bound
    uint256 public loanId;
    bool public bound;
    uint64 public bindNonce; // increments per binding; scopes the allowlist

    /// allowedWhileBound[bindNonce][target] — exec targets pinned at bind.
    mapping(uint64 => mapping(address => bool)) public allowedWhileBound;

    // statuses in LoanVault: Drawn=3, Grace=4; > 4 is terminal
    uint8 internal constant STATUS_GRACE = 4;

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address owner_) {
        owner = owner_;
    }

    /// @notice Rewards claimed with wrap=false arrive as native FLR.
    receive() external payable {}

    // ---------------------------------------------------------------- binding

    /// @notice Bind this account to one loan: from now until that loan is
    ///         terminal, value moves only to the loan's collector and exec()
    ///         reaches only `allowedTargets`. The vault, collector, and
    ///         allowlist are pinned here and cannot change mid-loan —
    ///         enrollment tooling shows the lender all three before funding.
    function bind(address vault_, uint256 loanId_, address collector_, address[] calldata allowedTargets)
        external
        onlyOwner
    {
        if (bound) revert AlreadyBound(loanId);
        address borrower = ILoanVaultForAccount(vault_).borrowerOf(loanId_);
        if (borrower != address(this) && borrower != owner) revert NotThisAccountsLoan();
        // MEDIUM-1: the collector must be the loan's REAL collector, read from
        // the vault — not a decoy the owner points rewards at to dodge repay.
        address realCollector = ILoanVaultForAccount(vault_).collectorOf(loanId_);
        if (collector_ != realCollector) revert WrongCollector(collector_, realCollector);

        // MEDIUM-2: revoke every approval this account granted while unbound,
        // so no standing allowance can drain a future reward past the fence.
        for (uint256 i; i < grantedApprovals.length; i++) {
            Approval memory a = grantedApprovals[i];
            (bool ok,) = a.token.call(abi.encodeCall(IERC20.approve, (a.spender, 0)));
            if (ok) emit ApprovalRevoked(a.token, a.spender);
        }
        delete grantedApprovals;

        vault = ILoanVaultForAccount(vault_);
        collector = collector_;
        loanId = loanId_;
        bound = true;
        bindNonce += 1;
        for (uint256 i; i < allowedTargets.length; i++) {
            // the collector is never a legal exec target, even if listed
            if (allowedTargets[i] != collector_) {
                allowedWhileBound[bindNonce][allowedTargets[i]] = true;
            }
        }
        emit Bound(loanId_, vault_, collector_);
    }

    /// @notice Anyone may release the binding once the loan is terminal
    ///         (Settled/Repaid/Closed). Self-expiring authorization — the
    ///         borrower never needs the lender's cooperation to get their
    ///         account back, and the lender never needs the borrower's to
    ///         keep it bound while debt is outstanding.
    function release() external {
        if (!bound) revert NotBound();
        if (vault.statusOf(loanId) <= STATUS_GRACE) revert LoanStillActive(loanId);
        bound = false;
        vault = ILoanVaultForAccount(address(0));
        collector = address(0);
        emit Released(loanId);
        loanId = 0;
    }

    // ------------------------------------------------------- while bound

    /// @notice Route held value to the loan's collector — the ONLY value
    ///         motion the binding permits. Callable by anyone (keepers), so
    ///         a claimed reward sitting here can always be pushed along.
    function routeToCollector(address token) external {
        if (!bound) revert NotBound();
        uint256 nativeBal = address(this).balance;
        if (nativeBal != 0) {
            (bool ok,) = collector.call{value: nativeBal}("");
            if (!ok) revert CallFailed();
            emit RoutedToCollector(address(0), nativeBal);
        }
        if (token != address(0)) {
            uint256 bal = IERC20(token).balanceOf(address(this));
            if (bal != 0) {
                if (!IERC20(token).transfer(collector, bal)) revert CallFailed();
                emit RoutedToCollector(token, bal);
            }
        }
    }

    // ------------------------------------------------------ owner control

    /// @notice The borrower's general-purpose hand. Unbound: full control.
    ///         Bound: no value may move, and the target must be on the
    ///         allowlist pinned at bind — everything else reverts.
    function exec(address target, uint256 value, bytes calldata data)
        external
        onlyOwner
        returns (bytes memory)
    {
        if (bound) {
            if (value != 0) revert BindingForbidsThis();
            if (!allowedWhileBound[bindNonce][target]) revert BindingForbidsThis();
        }
        // Record any ERC-20 approve() so the next bind() can revoke it
        // (MEDIUM-2). selector 0x095ea7b3 = approve(address,uint256).
        if (data.length >= 36 && bytes4(data[0:4]) == IERC20.approve.selector) {
            address spender = address(uint160(uint256(bytes32(data[4:36]))));
            grantedApprovals.push(Approval({token: target, spender: spender}));
        }
        (bool ok, bytes memory ret) = target.call{value: value}(data);
        if (!ok) revert CallFailed();
        return ret;
    }

    /// @notice Withdraw anything — ONLY while unbound.
    function sweepToOwner(address token) external onlyOwner {
        if (bound) revert BindingForbidsThis();
        uint256 nativeBal = address(this).balance;
        if (nativeBal != 0) {
            (bool ok,) = owner.call{value: nativeBal}("");
            if (!ok) revert CallFailed();
        }
        if (token != address(0)) {
            uint256 bal = IERC20(token).balanceOf(address(this));
            if (bal != 0 && !IERC20(token).transfer(owner, bal)) revert CallFailed();
        }
    }
}
