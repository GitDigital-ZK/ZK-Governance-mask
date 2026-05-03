sdk/GovernanceMask.ts

```typescript
import { ethers } from "ethers";
import * as snarkjs from "snarkjs";
import { AnchorProvider, Program, web3, BN } from "@coral-xyz/anchor";
import { GovernanceMask } from "../solana/target/types/governance_mask"; // generated IDL

/**
 * GovernanceMask SDK
 * Provides helper functions for proof generation, Ethereum and Solana voting.
 * All private witness data stays in the client – nothing leaks on‑chain.
 */

export interface GovernanceMaskProof {
  a: [bigint, bigint];
  b: [[bigint, bigint], [bigint, bigint]];
  c: [bigint, bigint];
  publicInputs: bigint[];
}

export interface VoteInput {
  address: bigint;             // field element representation of user's address
  balance: bigint;
  nullifierSecret: bigint;     // high‑entropy secret
  merkleProof: {
    root: bigint;
    pathElements: bigint[];
    pathIndex: number[];
  };
  voteOption: bigint;          // hash / identifier of the voting option
  scope: bigint;               // proposal identifier
  useWeighted: 0 | 1;
}

export class GovernanceMaskClient {
  private wasmFile: string;
  private zkeyFile: string;
  private ethereumVerifierAddress?: string;
  private solanaProgram?: Program<GovernanceMask>;
  private solanaProvider?: AnchorProvider;

  constructor(
    wasmPath: string,
    zkeyPath: string,
  ) {
    this.wasmFile = wasmPath;
    this.zkeyFile = zkeyPath;
  }

  /**
   * Initializes an Ethereum connection.
   */
  initEthereum(
    provider: ethers.Provider,
    verifierAddress: string,
    governanceAddress: string,
    signer?: ethers.Signer
  ) {
    if (!signer) signer = new ethers.Wallet(/* ... */); // demo
    this.ethereumVerifierAddress = verifierAddress;
    // Bind to the GovernanceMask contract
    // return new ethers.Contract(governanceAddress, GovernanceMaskAbi, signer);
  }

  /**
   * Initializes Solana connection.
   */
  async initSolana(provider: AnchorProvider, programId: web3.PublicKey) {
    this.solanaProvider = provider;
    const idl = await Program.fetchIdl(programId, provider);
    this.solanaProgram = new Program(idl!, programId, provider) as any;
  }

  /**
   * Generates a Groth16 proof for the given voter input.
   * All private parameters stay in the client.
   */
  async generateProof(input: VoteInput): Promise<GovernanceMaskProof> {
    const circuitInputs = {
      root: input.merkleProof.root.toString(),
      nullifierHash: "0", // placeholder, computed by circuit
      voteOption: input.voteOption.toString(),
      weight: input.useWeighted ? input.balance.toString() : "1",
      scope: input.scope.toString(),
      useWeighted: input.useWeighted.toString(),
      // private
      address: input.address.toString(),
      balance: input.balance.toString(),
      nullifierSecret: input.nullifierSecret.toString(),
      pathElements: input.merkleProof.pathElements.map(e => e.toString()),
      pathIndex: input.merkleProof.pathIndex.map(e => e.toString())
    };

    const { proof, publicSignals } = await snarkjs.groth16.fullProve(
      circuitInputs,
      this.wasmFile,
      this.zkeyFile
    );

    return {
      a: [BigInt(proof.pi_a[0]), BigInt(proof.pi_a[1])],
      b: [
        [BigInt(proof.pi_b[0][1]), BigInt(proof.pi_b[0][0])], // G2 repr.
        [BigInt(proof.pi_b[1][1]), BigInt(proof.pi_b[1][0])]
      ],
      c: [BigInt(proof.pi_c[0]), BigInt(proof.pi_c[1])],
      publicInputs: publicSignals.map((s: string) => BigInt(s))
    };
  }

  /**
   * Cast a vote on Ethereum.
   */
  async castVoteEthereum(
    contract: ethers.Contract,  // GovernanceMask contract instance
    proposalId: number,
    proof: GovernanceMaskProof
  ): Promise<ethers.ContractTransaction> {
    // The contract expects 6 public inputs (after the constant 1)
    const pubInputs = proof.publicInputs.slice(0, 6); // discard the leading "1" used by verifier
    return contract.castVote(
      proposalId,
      proof.a,
      proof.b,
      proof.c,
      pubInputs
    );
  }

  /**
   * Cast a vote on Solana.
   */
  async castVoteSolana(
    proposalPda: web3.PublicKey,
    proof: GovernanceMaskProof
  ): Promise<string> {
    if (!this.solanaProgram) throw new Error("Solana not initialized");
    // Serialize proof and public inputs as expected by the program
    const proofABytes = Buffer.concat([
      this.toBufferLE(proof.a[0], 32),
      this.toBufferLE(proof.a[1], 32)
    ]);
    const proofBBytes = Buffer.concat([
      this.toBufferLE(proof.b[0][0], 32),
      this.toBufferLE(proof.b[0][1], 32),
      this.toBufferLE(proof.b[1][0], 32),
      this.toBufferLE(proof.b[1][1], 32)
    ]);
    const proofCBytes = Buffer.concat([
      this.toBufferLE(proof.c[0], 32),
      this.toBufferLE(proof.c[1], 32)
    ]);
    const pubInputsBytes = Buffer.concat(
      proof.publicInputs.map((v) => this.toBufferLE(v, 32))
    );

    const tx = await this.solanaProgram!.methods
      .castVote(
        new BN(proposalPda), // proposal_id handled internally
        Array.from(proofABytes),
        Array.from(proofBBytes),
        Array.from(proofCBytes),
        Array.from(pubInputsBytes)
      )
      .accounts({
        governanceState: /* derived governance PDA */,
        proposal: proposalPda,
        verificationKey: /* verification key account */,
        systemProgram: web3.SystemProgram.programId,
      })
      .rpc();

    return tx;
  }

  private toBufferLE(value: bigint, bytes: number): Buffer {
    const hex = value.toString(16).padStart(bytes * 2, "0");
    return Buffer.from(hex, "hex").reverse(); // little-endian
  }
}
```

