#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

#[cfg(not(target_os = "windows"))]
compile_error!("The Swaw Kit Proj application V0 supports Windows only.");

mod tray;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    tray::run()
}
