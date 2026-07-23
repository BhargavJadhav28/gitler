use serde::{de::DeserializeOwned, Deserialize, Serialize};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

pub(crate) const VERSION: u16 = 1;
pub(crate) const ALPN: &[u8] = b"gitler/1";
pub(crate) const DIGEST_LENGTH: usize = 32;
const MAX_MESSAGE_LENGTH: usize = 16 * 1024;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct TransferRequest {
    pub(crate) version: u16,
    pub(crate) file_name: String,
    pub(crate) size: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct TransferResponse {
    pub(crate) accepted: bool,
    pub(crate) message: String,
}

impl TransferResponse {
    pub(crate) fn accepted(message: impl Into<String>) -> Self {
        Self {
            accepted: true,
            message: message.into(),
        }
    }

    pub(crate) fn rejected(message: impl Into<String>) -> Self {
        Self {
            accepted: false,
            message: message.into(),
        }
    }
}

#[derive(Debug, thiserror::Error)]
pub(crate) enum ProtocolError {
    #[error("protocol I/O failed: {0}")]
    Io(#[from] std::io::Error),

    #[error("protocol message is invalid: {0}")]
    Json(#[from] serde_json::Error),

    #[error("protocol message has {actual} bytes; maximum is {maximum}")]
    MessageTooLarge { actual: usize, maximum: usize },
}

pub(crate) async fn write_message<W, T>(writer: &mut W, value: &T) -> Result<(), ProtocolError>
where
    W: AsyncWrite + Unpin,
    T: Serialize,
{
    let payload = serde_json::to_vec(value)?;
    if payload.len() > MAX_MESSAGE_LENGTH {
        return Err(ProtocolError::MessageTooLarge {
            actual: payload.len(),
            maximum: MAX_MESSAGE_LENGTH,
        });
    }

    let length = u32::try_from(payload.len()).map_err(|_| ProtocolError::MessageTooLarge {
        actual: payload.len(),
        maximum: MAX_MESSAGE_LENGTH,
    })?;
    writer.write_all(&length.to_be_bytes()).await?;
    writer.write_all(&payload).await?;
    Ok(())
}

pub(crate) async fn read_message<R, T>(reader: &mut R) -> Result<T, ProtocolError>
where
    R: AsyncRead + Unpin,
    T: DeserializeOwned,
{
    let mut length_bytes = [0_u8; 4];
    reader.read_exact(&mut length_bytes).await?;
    let length = u32::from_be_bytes(length_bytes) as usize;
    if length > MAX_MESSAGE_LENGTH {
        return Err(ProtocolError::MessageTooLarge {
            actual: length,
            maximum: MAX_MESSAGE_LENGTH,
        });
    }

    let mut payload = vec![0_u8; length];
    reader.read_exact(&mut payload).await?;
    Ok(serde_json::from_slice(&payload)?)
}

#[cfg(test)]
mod tests {
    use tokio::io::AsyncWriteExt;

    use super::{
        read_message, write_message, ProtocolError, TransferRequest, MAX_MESSAGE_LENGTH, VERSION,
    };

    #[tokio::test]
    async fn message_should_round_trip() -> Result<(), Box<dyn std::error::Error>> {
        let expected = TransferRequest {
            version: VERSION,
            file_name: "notes.txt".to_owned(),
            size: 42,
        };
        let (mut writer, mut reader) = tokio::io::duplex(1024);

        write_message(&mut writer, &expected).await?;
        let actual: TransferRequest = read_message(&mut reader).await?;

        assert_eq!(actual, expected);
        Ok(())
    }

    #[tokio::test]
    async fn read_message_should_reject_oversized_declared_length(
    ) -> Result<(), Box<dyn std::error::Error>> {
        let (mut writer, mut reader) = tokio::io::duplex(4);
        writer
            .write_all(&((MAX_MESSAGE_LENGTH + 1) as u32).to_be_bytes())
            .await?;

        let error = read_message::<_, TransferRequest>(&mut reader)
            .await
            .unwrap_err();

        assert!(matches!(error, ProtocolError::MessageTooLarge { .. }));
        Ok(())
    }

    #[tokio::test]
    async fn read_message_should_reject_truncated_payload() -> Result<(), Box<dyn std::error::Error>>
    {
        let (mut writer, mut reader) = tokio::io::duplex(32);
        writer.write_all(&4_u32.to_be_bytes()).await?;
        writer.write_all(b"{}\n").await?;
        writer.shutdown().await?;

        let error = read_message::<_, TransferRequest>(&mut reader)
            .await
            .unwrap_err();

        assert!(matches!(error, ProtocolError::Io(_)));
        Ok(())
    }

    #[tokio::test]
    async fn read_message_should_reject_malformed_json() -> Result<(), Box<dyn std::error::Error>> {
        let payload = b"not-json";
        let (mut writer, mut reader) = tokio::io::duplex(64);
        writer
            .write_all(&(payload.len() as u32).to_be_bytes())
            .await?;
        writer.write_all(payload).await?;

        let error = read_message::<_, TransferRequest>(&mut reader)
            .await
            .unwrap_err();

        assert!(matches!(error, ProtocolError::Json(_)));
        Ok(())
    }

    #[tokio::test]
    async fn write_message_should_reject_oversized_serialized_payload(
    ) -> Result<(), Box<dyn std::error::Error>> {
        let payload = "x".repeat(MAX_MESSAGE_LENGTH);
        let (mut writer, _reader) = tokio::io::duplex(64);

        let error = write_message(&mut writer, &payload).await.unwrap_err();

        assert!(matches!(error, ProtocolError::MessageTooLarge { .. }));
        Ok(())
    }
}
