use notebook_typesetter_runtime::Runtime;
use std::{path::Path, sync::atomic::AtomicBool, time::{Duration, Instant}};
fn main() -> Result<(), String> {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 7 { return Err("wasm bundle.zip latex.fmt fonts.tsv source.tex output-directory".into()); }
    let format = std::fs::read(&args[3]).map_err(|e| e.to_string())?;
    let runtime = Runtime::new(Path::new(&args[2]), format, std::fs::read(&args[4]).map_err(|e| e.to_string())?)?;
    if args[1] == "format" {
        std::fs::write(Path::new(&args[6]).join("latex.fmt"), runtime.generate_format()?).map_err(|e| e.to_string())?;
        return Ok(());
    }
    for run in 0..3 {
        let started = Instant::now();
        let source = std::fs::read_to_string(&args[5]).map_err(|e| e.to_string())?;
        let output = if args[1] == "svg" { runtime.convert_svg(&source, Duration::from_secs(30), &AtomicBool::new(false)) } else { runtime.compile(&source, vec![], 0, Duration::from_secs(30), &AtomicBool::new(false)) }?;
        println!("run={run} elapsed={:?} memory={} pdf={} synctex={}\n{}", started.elapsed(), output.memory_bytes, output.pdf.len(), output.synctex.len(), output.log);
        std::fs::write(Path::new(&args[6]).join("document.pdf"), output.pdf).map_err(|e| e.to_string())?;
        std::fs::write(Path::new(&args[6]).join("document.synctex.gz"), output.synctex).map_err(|e| e.to_string())?;
    }
    Ok(())
}
