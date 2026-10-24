// Embute o ícone do app (`client\icon.ico`) como recurso `MAINICON`.
fn main() {
    // O ícone é do exe do Windows; a biblioteca também é compilada para Android.
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("windows") {
        return;
    }
    println!("cargo:rerun-if-changed=rtsplayer.rc");
    println!("cargo:rerun-if-changed=icon.ico");
    embed_resource::compile("rtsplayer.rc", embed_resource::NONE).manifest_optional().expect("falha ao compilar rtsplayer.rc (rc.exe do Windows SDK)");
}
