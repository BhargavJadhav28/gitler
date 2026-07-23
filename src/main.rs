use std::process::ExitCode;

#[tokio::main]
async fn main() -> ExitCode {
    match gitler::run().await {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("error: {error:#}");
            ExitCode::FAILURE
        }
    }
}
