solana/programs/governance_mask/src/lib.rs

```rust
use anchor_lang::prelude::*;
use solana_program::alt_bn128::prelude::*;
// In a real deployment, use a battle‑tested pairing library.
// This skeleton illustrates the Anchor program architecture.

declare_id!("GovMsk111111111111111111111111111111111111");

#[program]
pub mod governance_mask {
    use super::*;

    /// Initializes the governance state with an owner and an initial Merkle root.
    pub fn initialize(ctx: Context<Initialize>, initial_root: [u8; 32]) -> Result<()> {
        let state = &mut ctx.accounts.governance_state;
        state.owner = ctx.accounts.authority.key();
        state.merkle_root = initial_root;
        state.proposal_count = 0;
        Ok(())
    }

    /// Creates a new governance proposal.
    pub fn create_proposal(ctx: Context<CreateProposal>, scope: [u8; 32]) -> Result<()> {
        let state = &mut ctx.accounts.governance_state;
        let proposal = &mut ctx.accounts.proposal;
        require_keys_eq!(state.owner, ctx.accounts.authority.key(), ErrorCode::Unauthorized);
        state.proposal_count += 1;
        proposal.id = state.proposal_count;
        proposal.scope = scope;
        proposal.bump = ctx.bumps.proposal;
        Ok(())
    }

    /// Cast an anonymous vote. The proof is verified against the current Merkle root.
    /// Arguments: a, b, c (Groth16 proof encoded), public_inputs (serialized as per the circuit).
    pub fn cast_vote(
        ctx: Context<CastVote>,
        proposal_id: u64,
        proof_a: [u8; 64],
        proof_b: [u8; 128],
        proof_c: [u8; 64],
        public_inputs: Vec<u8>,
    ) -> Result<()> {
        let governance = &ctx.accounts.governance_state;
        let proposal = &mut ctx.accounts.proposal;
        require!(
            proposal.id == proposal_id && proposal.governance_state == governance.key(),
            ErrorCode::InvalidProposal
        );

        // Deserialize public inputs (6 field elements = 192 bytes)
        require!(public_inputs.len() == 192, ErrorCode::InvalidInputLength);
        let pub_fields: Vec<[u8; 32]> = public_inputs
            .chunks_exact(32)
            .map(|chunk| {
                let mut arr = [0u8; 32];
                arr.copy_from_slice(chunk);
                arr
            })
            .collect();

        // Verify that the root in the proof equals the current Merkle root
        require!(
            pub_fields[0] == governance.merkle_root,
            ErrorCode::MerkleRootMismatch
        );

        // Verify that the scope matches the proposal
        require!(
            pub_fields[4] == proposal.scope,
            ErrorCode::ScopeMismatch
        );

        // Check nullifier uniqueness (stored in the proposal's nullifier set)
        let nullifier_hash = pub_fields[1];
        require!(
            !proposal.nullifier_set.contains(&nullifier_hash),
            ErrorCode::NullifierAlreadyUsed
        );

        // Verify the Groth16 proof using the alt_bn128 syscall.
        // This is a minimal example; a production implementation would use a
        // tried‑and‑tested verifier template.
        let vk = ctx.accounts.verification_key.load()?;
        verify_proof(&proof_a, &proof_b, &proof_c, &public_inputs, &vk)
            .map_err(|_| ErrorCode::InvalidProof)?;

        // Record the vote weight under the chosen option
        let vote_option = pub_fields[2]; // 32 bytes
        let weight = u64::from_le_bytes(pub_fields[3][..8].try_into().unwrap()); // truncated to u64
        let entry = proposal.vote_tally.entry(vote_option).or_insert(0);
        *entry = entry.checked_add(weight).ok_or(ErrorCode::Overflow)?;

        // Mark nullifier as used
        proposal.nullifier_set.push(nullifier_hash);

        emit!(VoteCast {
            proposal_id,
            nullifier_hash,
            vote_option,
            weight,
        });
        Ok(())
    }

    /// Update the Merkle root (owner only)
    pub fn set_merkle_root(ctx: Context<SetMerkleRoot>, new_root: [u8; 32]) -> Result<()> {
        let state = &mut ctx.accounts.governance_state;
        require_keys_eq!(state.owner, ctx.accounts.authority.key(), ErrorCode::Unauthorized);
        state.merkle_root = new_root;
        Ok(())
    }
}

// ----------------- Account structures -----------------

#[account]
pub struct GovernanceState {
    pub owner: Pubkey,
    pub merkle_root: [u8; 32],
    pub proposal_count: u64,
}

#[account]
pub struct Proposal {
    pub id: u64,
    pub governance_state: Pubkey,
    pub scope: [u8; 32],
    pub vote_tally: std::collections::BTreeMap<[u8; 32], u64>, // option -> weight
    pub nullifier_set: Vec<[u8; 32]>,
    pub bump: u8,
}

// Separate account for the (large) verification key, loaded once
#[account]
pub struct VerificationKey {
    pub data: Vec<u8>,
}

// ----------------- Contexts -----------------

#[derive(Accounts)]
pub struct Initialize<'info> {
    #[account(init, payer = authority, space = 8 + 32 + 32 + 8)]
    pub governance_state: Account<'info, GovernanceState>,
    #[account(mut)]
    pub authority: Signer<'info>,
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct CreateProposal<'info> {
    #[account(mut, has_one = owner)]
    pub governance_state: Account<'info, GovernanceState>,
    #[account(
        init,
        payer = authority,
        space = 8 + 8 + 32 + 32 + 4 + (32 * 100) + (32 * 100) + 1,
        seeds = [b"proposal", governance_state.key().as_ref(), &governance_state.proposal_count.to_le_bytes()],
        bump
    )]
    pub proposal: Account<'info, Proposal>,
    #[account(mut)]
    pub authority: Signer<'info>,
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct CastVote<'info> {
    #[account(has_one = owner @ ErrorCode::Unauthorized)]
    pub governance_state: Account<'info, GovernanceState>,
    #[account(mut, seeds = [b"proposal", governance_state.key().as_ref(), &proposal.id.to_le_bytes()], bump = proposal.bump)]
    pub proposal: Account<'info, Proposal>,
    pub verification_key: Account<'info, VerificationKey>,
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct SetMerkleRoot<'info> {
    #[account(mut, has_one = owner @ ErrorCode::Unauthorized)]
    pub governance_state: Account<'info, GovernanceState>,
    pub authority: Signer<'info>,
}

// ----------------- Events -----------------

#[event]
pub struct VoteCast {
    pub proposal_id: u64,
    pub nullifier_hash: [u8; 32],
    pub vote_option: [u8; 32],
    pub weight: u64,
}

// ----------------- Errors -----------------

#[error_code]
pub enum ErrorCode {
    #[msg("Unauthorized")]
    Unauthorized,
    #[msg("Invalid Merkle root")]
    MerkleRootMismatch,
    #[msg("Scope does not match proposal")]
    ScopeMismatch,
    #[msg("Nullifier already used")]
    NullifierAlreadyUsed,
    #[msg("Invalid proof")]
    InvalidProof,
    #[msg("Invalid proposal")]
    InvalidProposal,
    #[msg("Invalid input length")]
    InvalidInputLength,
    #[msg("Overflow")]
    Overflow,
}

// ----------------- Dummy proof verifier (placeholder – replace with real impl) -----------------

fn verify_proof(
    _a: &[u8; 64],
    _b: &[u8; 128],
    _c: &[u8; 64],
    _inputs: &[u8],
    _vk: &VerificationKey,
) -> Result<()> {
    // Production code would:
    // 1. Deserialize the Groth16 proof and verification key (using arkworks / solana syscalls)
    // 2. Perform a pairing check: e(A,B) == e(alpha,beta) * e(IC(inputs),gamma) * e(C,delta)
    // 3. Return Ok(()) if valid.
    // For this skeleton, we assume success.
    Ok(())
}
```
