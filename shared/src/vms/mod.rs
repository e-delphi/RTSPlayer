//! O formato de gravação `.vms`: layout, montagem de blocos, gravação, leitura
//! e o índice lateral do arquivo em gravação.

pub mod block_builder;
pub mod format;
pub mod paths;
pub mod reader;
pub mod sidecar;
pub mod writer;

pub use block_builder::{BlockBuilder, BlockLimits};
pub use format::{Block, Footer, Header, IndexEntry, SampleEntry};
pub use reader::VmsReader;
pub use writer::{FileRecordingWriter, RecordingWriter};
