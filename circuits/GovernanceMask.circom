circuits/GovernanceMask.circom

```circom
pragma circom 2.0.0;

include "circomlib/circuits/poseidon.circom";
include "circomlib/circuits/multiplexer.circom";
include "circomlib/circuits/comparators.circom";

// Governance Mask ZK Circuit
//
// Proves that a voter has a valid leaf in a Merkle tree, generates a unique
// nullifier to prevent double-voting, and optionally proves a voting weight
// derived from a hidden balance.
//
// Public Inputs:
//   root           Merkle tree root
//   nullifierHash  Poseidon(nullifierSecret, scope)
//   voteOption     Unique identifier of the vote choice
//   weight         Vote weight (1 if non-weighted, balance if weighted)
//   scope          Proposal/vote identifier, used in nullifier
//   useWeighted    0 = equal voting (weight = 1), 1 = weight = balance
//
// Private Inputs:
//   address        Voter's public address (field element)
//   balance        Voter's token balance (user‑provided, hidden)
//   nullifierSecret  High‑entropy secret for nullifier derivation
//   pathElements   Merkle proof siblings (depth = TREE_DEPTH)
//   pathIndex      Direction selector for each level (0 = left, 1 = right)

template GovernanceMask(TREE_DEPTH) {
    // Public signals
    signal input root;
    signal input nullifierHash;
    signal input voteOption;
    signal input weight;
    signal input scope;
    signal input useWeighted;
    
    // Private signals
    signal input address;
    signal input balance;
    signal input nullifierSecret;
    signal input pathElements[TREE_DEPTH];
    signal input pathIndex[TREE_DEPTH];
    
    // ---------- 1. Compute leaf commitment ----------
    component leafHasher = Poseidon(3);
    leafHasher.inputs[0] <== address;
    leafHasher.inputs[1] <== balance;
    leafHasher.inputs[2] <== nullifierSecret;
    signal leafHash;
    leafHash <== leafHasher.out;
    
    // ---------- 2. Merkle inclusion proof ----------
    component mux[TREE_DEPTH];
    component merkleHasher[TREE_DEPTH];
    signal intermediateHash[TREE_DEPTH + 1];
    intermediateHash[0] <== leafHash;
    
    for (var i = 0; i < TREE_DEPTH; i++) {
        mux[i] = MultiMux1();
        // Order: left input is the hash being computed, right is the sibling
        // If pathIndex = 0, we are the left leaf; sibling goes to right.
        // If pathIndex = 1, sibling goes to left and we are right.
        mux[i].c[0] <== intermediateHash[i];
        mux[i].c[1] <== pathElements[i];
        mux[i].s <== pathIndex[i];
        
        signal leftInput;
        signal rightInput;
        leftInput <== mux[i].out[0];   // left child for the hash
        rightInput <== mux[i].out[1];  // right child for the hash
        
        merkleHasher[i] = Poseidon(2);
        merkleHasher[i].inputs[0] <== leftInput;
        merkleHasher[i].inputs[1] <== rightInput;
        intermediateHash[i + 1] <== merkleHasher[i].out;
    }
    
    // Root check
    root === intermediateHash[TREE_DEPTH];
    
    // ---------- 3. Nullifier derivation ----------
    component nullifierHasher = Poseidon(2);
    nullifierHasher.inputs[0] <== nullifierSecret;
    nullifierHasher.inputs[1] <== scope;
    nullifierHasher.out === nullifierHash;
    
    // ---------- 4. Weight correctness ----------
    // If useWeighted == 1  => weight must equal balance
    // If useWeighted == 0  => weight must equal 1
    // Constraint: useWeighted * (weight - balance) + (1 - useWeighted) * (weight - 1) = 0
    signal diffWeighted <-- weight - balance;
    signal diffUnweighted <-- weight - 1;
    signal weightedPart <-- useWeighted * diffWeighted;
    signal unweightedPart <-- (1 - useWeighted) * diffUnweighted;
    signal total <-- weightedPart + unweightedPart;
    total === 0;
    
    // Ensure useWeighted is boolean (enforced indirectly via above equation)
    // But we can add an explicit binary check:
    signal checkBinary <-- useWeighted * (1 - useWeighted);
    checkBinary === 0;
}

// Export main component with a sensible default depth (e.g., 20)
component main {public [root, nullifierHash, voteOption, weight, scope, useWeighted]} = GovernanceMask(20);
```
