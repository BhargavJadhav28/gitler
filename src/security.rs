use std::sync::Arc;

use quinn::crypto::rustls::{QuicClientConfig, QuicServerConfig};
use rustls::{
    client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier},
    pki_types::{CertificateDer, PrivatePkcs8KeyDer, ServerName, UnixTime},
    DigitallySignedStruct, SignatureScheme,
};
use sha2::{Digest, Sha256};

use crate::protocol::ALPN;

pub(crate) struct Identity {
    pub(crate) server_config: quinn::ServerConfig,
    pub(crate) fingerprint: [u8; 32],
}

#[derive(Debug, thiserror::Error)]
pub(crate) enum SecurityError {
    #[error("failed to generate ephemeral certificate: {0}")]
    Certificate(#[from] rcgen::Error),

    #[error("failed to configure TLS: {0}")]
    Tls(#[from] rustls::Error),

    #[error("failed to configure QUIC TLS: {0}")]
    Quic(String),
}

impl Identity {
    pub(crate) fn generate() -> Result<Self, SecurityError> {
        let rcgen::CertifiedKey { cert, signing_key } =
            rcgen::generate_simple_self_signed(vec!["gitler.local".to_owned()])?;
        let certificate = CertificateDer::from(cert);
        let fingerprint = Sha256::digest(certificate.as_ref()).into();
        let private_key = PrivatePkcs8KeyDer::from(signing_key.serialize_der());

        let mut tls = rustls::ServerConfig::builder()
            .with_no_client_auth()
            .with_single_cert(vec![certificate], private_key.into())?;
        tls.alpn_protocols = vec![ALPN.to_vec()];

        let crypto = QuicServerConfig::try_from(tls)
            .map_err(|error| SecurityError::Quic(error.to_string()))?;
        let mut server_config = quinn::ServerConfig::with_crypto(Arc::new(crypto));
        server_config.max_incoming(64);

        Ok(Self {
            server_config,
            fingerprint,
        })
    }
}

pub(crate) fn pinned_client_config(
    expected_fingerprint: [u8; 32],
) -> Result<quinn::ClientConfig, SecurityError> {
    let verifier = FingerprintVerifier::new(expected_fingerprint);
    let mut tls = rustls::ClientConfig::builder()
        .dangerous()
        .with_custom_certificate_verifier(verifier)
        .with_no_client_auth();
    tls.alpn_protocols = vec![ALPN.to_vec()];

    let crypto =
        QuicClientConfig::try_from(tls).map_err(|error| SecurityError::Quic(error.to_string()))?;
    Ok(quinn::ClientConfig::new(Arc::new(crypto)))
}

#[derive(Debug)]
struct FingerprintVerifier {
    expected: [u8; 32],
    provider: Arc<rustls::crypto::CryptoProvider>,
}

impl FingerprintVerifier {
    fn new(expected: [u8; 32]) -> Arc<Self> {
        Arc::new(Self {
            expected,
            provider: Arc::new(rustls::crypto::ring::default_provider()),
        })
    }
}

fn verify_fingerprint(
    certificate: &CertificateDer<'_>,
    expected: [u8; 32],
) -> Result<(), rustls::Error> {
    let actual: [u8; 32] = Sha256::digest(certificate.as_ref()).into();
    if actual != expected {
        return Err(rustls::Error::General(
            "receiver certificate fingerprint does not match mDNS advertisement".to_owned(),
        ));
    }

    Ok(())
}

impl ServerCertVerifier for FingerprintVerifier {
    fn verify_server_cert(
        &self,
        end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _server_name: &ServerName<'_>,
        _ocsp_response: &[u8],
        _now: UnixTime,
    ) -> Result<ServerCertVerified, rustls::Error> {
        verify_fingerprint(end_entity, self.expected)?;
        Ok(ServerCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        message: &[u8],
        certificate: &CertificateDer<'_>,
        signature: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls12_signature(
            message,
            certificate,
            signature,
            &self.provider.signature_verification_algorithms,
        )
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        certificate: &CertificateDer<'_>,
        signature: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls13_signature(
            message,
            certificate,
            signature,
            &self.provider.signature_verification_algorithms,
        )
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        self.provider
            .signature_verification_algorithms
            .supported_schemes()
    }
}

#[cfg(test)]
mod tests {
    use rustls::pki_types::CertificateDer;
    use sha2::{Digest, Sha256};

    use super::verify_fingerprint;

    fn certificate() -> Result<CertificateDer<'static>, rcgen::Error> {
        let rcgen::CertifiedKey { cert, .. } =
            rcgen::generate_simple_self_signed(vec!["gitler.local".to_owned()])?;
        Ok(CertificateDer::from(cert))
    }

    #[test]
    fn verify_fingerprint_should_accept_matching_certificate(
    ) -> Result<(), Box<dyn std::error::Error>> {
        let certificate = certificate()?;
        let fingerprint: [u8; 32] = Sha256::digest(certificate.as_ref()).into();

        verify_fingerprint(&certificate, fingerprint)?;

        Ok(())
    }

    #[test]
    fn verify_fingerprint_should_reject_mismatch() -> Result<(), Box<dyn std::error::Error>> {
        let certificate = certificate()?;
        let mut fingerprint: [u8; 32] = Sha256::digest(certificate.as_ref()).into();
        fingerprint[0] ^= 1;

        let error = verify_fingerprint(&certificate, fingerprint).unwrap_err();

        assert!(error
            .to_string()
            .contains("receiver certificate fingerprint does not match mDNS advertisement"));
        Ok(())
    }
}
