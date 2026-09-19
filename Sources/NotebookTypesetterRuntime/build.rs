fn main() {
    let stage = std::env::var("NOTEBOOK_TYPESETTER_NATIVE").expect("prepare_notebook_typesetter.py must prepare the pinned AOT library");
    println!("cargo:rustc-link-search=native={stage}");
    println!("cargo:rustc-link-lib=static=notebook_engine");
    println!("cargo:rerun-if-env-changed=NOTEBOOK_TYPESETTER_NATIVE");
    println!("cargo:rerun-if-changed={stage}/libnotebook_engine.a");
}
