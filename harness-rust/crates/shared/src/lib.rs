//! # shared
//!
//! Common types, error handling, logging, file locking, and git utilities
//! used by all crates in the rev_harness workspace.
//!
//! This crate is the foundation layer — every other crate depends on it.

pub mod error;
pub mod freshness;
pub mod git;
pub mod lock;
pub mod logging;
pub mod paths;
pub mod ranker;
pub mod types;
pub mod validation;

#[cfg(test)]
pub(crate) mod test_env;

// Re-export the most commonly used items at the crate root.
pub use error::{AgentError, Result};
pub use types::*;
