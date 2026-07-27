use std::process::ExitCode;

#[tokio::main]
async fn main() -> ExitCode {
    match gitler::run().await {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("gitler: error: {error:#}");
            eprintln!("Run `gitler --help` for usage.");
            ExitCode::FAILURE
        }
    }
}
