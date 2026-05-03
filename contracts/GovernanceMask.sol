contracts/GovernanceMask.sol

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./MaskVerifier.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title GovernanceMask
 * @notice Anonymous, Sybil‑resistant on‑chain governance with zero‑knowledge voting.
 *         Integrates a Merkle‑root registry of eligible voters and unique nullifiers
 *         to prevent double‑voting.
 */
contract GovernanceMask is Ownable {
    MaskVerifier public verifier;

    // ---------- Proposal management ----------
    struct Proposal {
        bytes32 scope;          // Unique scope used in nullifier derivation
        mapping(bytes32 => uint256) votes;  // voteOption => total weight
        mapping(uint256 => bool) nullifierUsed; // nullifierHash => used
        bool exists;
    }

    uint256 public proposalCount;
    mapping(uint256 => Proposal) public proposals;

    // Current valid Merkle root (updated atomically by the operator)
    bytes32 public merkleRoot;

    // Events
    event ProposalCreated(uint256 indexed proposalId, bytes32 scope);
    event MerkleRootUpdated(bytes32 newRoot);
    event VoteCast(
        uint256 indexed proposalId,
        bytes32 nullifierHash,
        bytes32 voteOption,
        uint256 weight
    );

    constructor(address _verifier, bytes32 _initialMerkleRoot) Ownable(msg.sender) {
        require(_verifier != address(0), "Invalid verifier");
        verifier = MaskVerifier(_verifier);
        merkleRoot = _initialMerkleRoot;
    }

    /**
     * @notice Creates a new governance proposal with a unique scope.
     * @param scope A unique identifier (e.g., hash of proposal description).
     *              Will be used inside the ZK nullifier to scope votes.
     */
    function createProposal(bytes32 scope) external onlyOwner {
        proposalCount++;
        Proposal storage p = proposals[proposalCount];
        p.scope = scope;
        p.exists = true;
        emit ProposalCreated(proposalCount, scope);
    }

    /**
     * @notice Updates the Merkle root that defines the set of eligible voters.
     * @param newRoot New root (must be computed off‑chain from token holders).
     */
    function setMerkleRoot(bytes32 newRoot) external onlyOwner {
        merkleRoot = newRoot;
        emit MerkleRootUpdated(newRoot);
    }

    /**
     * @notice Cast an anonymous vote on a proposal.
     * @param proposalId The proposal identifier.
     * @param a G1 point of the Groth16 proof.
     * @param b G2 point of the proof.
     * @param c G1 point of the proof.
     * @param pubInputs Array of 6 public inputs:
     *        [0] root
     *        [1] nullifierHash
     *        [2] voteOption
     *        [3] weight
     *        [4] scope
     *        [5] useWeighted
     */
    function castVote(
        uint256 proposalId,
        uint256[2] calldata a,
        uint256[2][2] calldata b,
        uint256[2] calldata c,
        uint256[6] calldata pubInputs
    ) external {
        Proposal storage proposal = proposals[proposalId];
        require(proposal.exists, "Proposal does not exist");

        // Verify the ZK proof
        uint256[] memory inputs = new uint256[](7);
        // The verifier expects an input array of length IC_LENGTH (7),
        // usually starting with a dummy "1" for Groth16.
        inputs[0] = 1; // conventional Groth16 constant
        for (uint i = 0; i < 6; i++) {
            inputs[i + 1] = pubInputs[i];
        }
        require(
            verifier.verify(a, b, c, inputs),
            "Invalid proof"
        );

        // Ensure the root matches the current eligible set
        require(bytes32(pubInputs[0]) == merkleRoot, "Invalid Merkle root");

        // Ensure the scope matches the proposal
        require(bytes32(pubInputs[4]) == proposal.scope, "Scope mismatch");

        // Check nullifier uniqueness
        uint256 nullifierHash = pubInputs[1];
        require(!proposal.nullifierUsed[nullifierHash], "Nullifier already used");
        proposal.nullifierUsed[nullifierHash] = true;

        // Record the weighted vote
        bytes32 voteOption = bytes32(pubInputs[2]);
        uint256 weight = pubInputs[3];
        proposal.votes[voteOption] += weight;

        emit VoteCast(proposalId, bytes32(nullifierHash), voteOption, weight);
    }

    /**
     * @notice Retrieve the total weight cast for a specific option on a proposal.
     */
    function getVoteCount(uint256 proposalId, bytes32 option) external view returns (uint256) {
        return proposals[proposalId].votes[option];
    }
}
```
