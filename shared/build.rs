// Embute a interface web (`shared/ui/`) na biblioteca: o app e o servidor
// servem as mesmas páginas, e o runtime é só o executável. Gera `ui_assets.rs`
// no OUT_DIR com a lista (nome, bytes). Editar a interface pede `cargo build`
// — ou, no desenvolvimento, a variável VMS_UI_DIR apontando para a pasta.
use std::path::PathBuf;

fn main() {
    let root = PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").unwrap()).join("ui");
    println!("cargo:rerun-if-changed={}", root.display());
    let mut files: Vec<PathBuf> = std::fs::read_dir(&root).expect("pasta ui").flatten().map(|e| e.path()).filter(|p| p.is_file()).collect();
    files.sort();
    let mut code = String::from("pub static UI_FILES: &[(&str, &[u8])] = &[\n");
    for p in files {
        println!("cargo:rerun-if-changed={}", p.display());
        let name = p.file_name().unwrap().to_string_lossy().into_owned();
        code += &format!("    ({name:?}, include_bytes!({:?})),\n", p.display().to_string());
    }
    code += "];\n";
    std::fs::write(PathBuf::from(std::env::var("OUT_DIR").unwrap()).join("ui_assets.rs"), code).unwrap();
}
