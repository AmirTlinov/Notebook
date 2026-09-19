//! Data-only SVG print child. Its signed executable inherits the markup App
//! Sandbox. This adapter owns admission and uses krilla/usvg for all rendering.
use std::io::{Read, Write};
use std::sync::{Arc, Mutex, atomic::{AtomicBool, Ordering}};
use krilla::{Document, geom::Size, page::PageSettings};
use krilla_svg::{SurfaceExt, SvgSettings};

const MAX_BYTES: usize = 8 * 1024 * 1024;
struct Diagnostics { active: AtomicBool, messages: Mutex<Vec<String>> }
static DIAGNOSTICS: Diagnostics = Diagnostics { active: AtomicBool::new(false), messages: Mutex::new(Vec::new()) };
impl log::Log for Diagnostics {
    fn enabled(&self, metadata: &log::Metadata) -> bool { metadata.level() <= log::Level::Warn && self.active.load(Ordering::Relaxed) }
    fn log(&self, record: &log::Record) {
        if self.enabled(record.metadata()) {
            let mut messages = self.messages.lock().unwrap();
            if messages.len() < 16 { messages.push(format!("{}", record.args()).chars().take(400).collect()); }
        }
    }
    fn flush(&self) {}
}

fn validate_svg(data: &[u8]) -> Result<(), String> {
    let text = std::str::from_utf8(data).map_err(|_| "SVG must be UTF-8".to_string())?;
    let document = usvg::roxmltree::Document::parse_with_options(text, usvg::roxmltree::ParsingOptions {
        allow_dtd: false, nodes_limit: 200_000, ..Default::default()
    }).map_err(|e| format!("Invalid SVG: {e}"))?;
    for node in document.descendants().filter(|n| n.is_element()) {
        let tag = node.tag_name().name();
        if ["foreignObject", "script", "animate", "animateMotion", "animateTransform", "set"].contains(&tag) {
            return Err(format!("export_svg_unsupported: {tag} has no static print representation"));
        }
        for attribute in node.attributes() {
            let value = attribute.value().trim();
            if attribute.name() == "href" && ["image", "use", "feImage"].contains(&tag)
                && !value.starts_with('#') && !value.starts_with("data:") {
                return Err("export_svg_resource_unavailable: images and references must be embedded".into());
            }
        }
        if tag == "style" && node.text().is_some_and(|v| v.contains('@')) {
            return Err("export_svg_unsupported: CSS at-rules require a precomputed static SVG".into());
        }
    }
    Ok(())
}

fn convert(data: &[u8]) -> Result<Vec<u8>, String> {
    if data.is_empty() || data.len() > MAX_BYTES { return Err("SVG exceeds 8 MiB".into()); }
    validate_svg(data)?;
    let mut options = usvg::Options::default();
    #[cfg(not(target_os = "wasi"))] {
        // Only OS-distributed fonts, never private or network font folders.
        options.fontdb_mut().load_fonts_dir("/System/Library/Fonts");
        options.fontdb_mut().set_serif_family("Times New Roman");
        options.fontdb_mut().set_sans_serif_family("Arial");
        options.fontdb_mut().set_monospace_family("Courier New");
    }
    #[cfg(target_os = "wasi")] {
        load_bundle_fonts(options.fontdb_mut())?;
        let select = usvg::FontResolver::default_font_selector();
        options.font_resolver.select_font = Box::new(move |font, database| materialize_font(select(font, database)?, database));
        options.font_resolver.select_fallback = Box::new(move |character, excluded, database| {
            let base = database.face(*excluded.first()?)?.clone();
            let candidates: Vec<_> = database.faces().filter(|f| !excluded.contains(&f.id) &&
                f.style == base.style && f.weight == base.weight && f.stretch == base.stretch).cloned().collect();
            for face in candidates {
                let bytes = match &face.source {
                    usvg::fontdb::Source::File(path) => std::fs::read(path).ok(),
                    _ => database.with_face_data(face.id, |data, _| data.to_vec()),
                };
                if let Some(bytes) = bytes {
                    if ttf_parser::Face::parse(&bytes, face.index).ok().and_then(|f| f.glyph_index(character)).is_some() {
                        return materialize_font(face.id, database);
                    }
                }
            }
            None
        });
    }
    let denied = Arc::new(AtomicBool::new(false));
    let denied_external = denied.clone();
    options.image_href_resolver.resolve_string = Box::new(move |_, _| {
        denied_external.store(true, Ordering::Relaxed); None
    });
    let default_data = usvg::ImageHrefResolver::default_data_resolver();
    let denied_data = denied.clone();
    options.image_href_resolver.resolve_data = Box::new(move |mime, bytes, opts| {
        // The default resolver sniffs text/plain as SVG, bypassing explicit
        // XML admission. Require a declared image MIME for every nested image.
        if !["image/svg+xml", "image/png", "image/jpeg", "image/jpg", "image/gif", "image/webp"].contains(&mime)
            || bytes.len() > MAX_BYTES || (mime == "image/svg+xml" && validate_svg(&bytes).is_err()) {
            denied_data.store(true, Ordering::Relaxed); return None;
        }
        let result = default_data(mime, bytes, opts);
        if result.is_none() { denied_data.store(true, Ordering::Relaxed); }
        result
    });
    DIAGNOSTICS.messages.lock().unwrap().clear();
    DIAGNOSTICS.active.store(true, Ordering::Relaxed);
    let tree = usvg::Tree::from_data(data, &options).map_err(|e| format!("Invalid SVG: {e}"))?;
    if denied.load(Ordering::Relaxed) { return Err("export_svg_resource_unavailable: embedded resource could not be resolved".into()); }
    let (width, height) = (tree.size().width(), tree.size().height());
    if width > 16384.0 || height > 16384.0 || width * height > 16_777_216.0 { return Err("SVG exceeds 16384 px / 16 megapixels".into()); }
    let size = Size::from_wh(width, height).ok_or("SVG has invalid dimensions")?;
    let mut document = Document::new();
    let mut page = document.start_page_with(PageSettings::new(size));
    let mut surface = page.surface();
    surface.draw_svg(&tree, size, SvgSettings::default()).ok_or("SVG rendering failed")?;
    surface.finish(); page.finish();
    let pdf = document.finish().map_err(|e| format!("SVG PDF failed: {e:?}"))?;
    let warnings = DIAGNOSTICS.messages.lock().unwrap();
    if !warnings.is_empty() { return Err(format!("export_svg_unsupported: {}", warnings.join("; "))); }
    if pdf.len() > MAX_BYTES { return Err("SVG PDF exceeds 8 MiB".into()); }
    Ok(pdf)
}

#[cfg(target_os = "wasi")]
fn materialize_font(id: usvg::fontdb::ID, database: &mut Arc<usvg::fontdb::Database>) -> Option<usvg::fontdb::ID> {
    let mut face = database.face(id)?.clone();
    if let usvg::fontdb::Source::File(path) = &face.source {
        // WASI has no mmap. Load only the selected face, through the bounded
        // virtual filesystem; never silently drop text after mmap fails.
        face.source = usvg::fontdb::Source::Binary(Arc::new(std::fs::read(path).ok()?));
        let database = Arc::make_mut(database); database.remove_face(id);
        Some(database.push_face_info(face))
    } else { Some(id) }
}

#[cfg(target_os = "wasi")]
fn load_bundle_fonts(database: &mut usvg::fontdb::Database) -> Result<(), String> {
    use usvg::fontdb::{FaceInfo, ID, Source, Language, Style, Weight, Stretch};
    let index = std::fs::read_to_string("/fonts/notebook-fonts.tsv").map_err(|e| e.to_string())?;
    for line in index.lines() {
        let fields: Vec<_> = line.split('\t').collect();
        if fields.len() != 9 { return Err("Invalid pinned font metadata".into()); }
        let stretch = match fields[6] { "1" => Stretch::UltraCondensed, "2" => Stretch::ExtraCondensed,
            "3" => Stretch::Condensed, "4" => Stretch::SemiCondensed, "6" => Stretch::SemiExpanded,
            "7" => Stretch::Expanded, "8" => Stretch::ExtraExpanded, "9" => Stretch::UltraExpanded, _ => Stretch::Normal };
        database.push_face_info(FaceInfo { id: ID::dummy(), source: Source::File(format!("/fonts/{}", fields[0]).into()), index: 0,
            families: fields[2].split('|').map(|v| (v.into(), Language::English_UnitedStates)).collect(),
            post_script_name: fields[1].into(), weight: Weight(fields[5].parse().map_err(|_| "Invalid font weight")?),
            style: match fields[7] { "italic" => Style::Italic, "oblique" => Style::Oblique, _ => Style::Normal },
            stretch, monospaced: fields[8] == "1" });
    }
    database.set_serif_family("Libertinus Serif"); database.set_sans_serif_family("Libertinus Sans"); database.set_monospace_family("Libertinus Mono");
    Ok(())
}

#[cfg(target_os = "wasi")]
#[unsafe(no_mangle)]
pub extern "C" fn notebook_image_compile() -> i32 {
    let _ = log::set_logger(&DIAGNOSTICS); log::set_max_level(log::LevelFilter::Warn);
    let result = (|| {
        let input = std::fs::read("/input/image.svg").map_err(|e| e.to_string())?;
        std::fs::write("/output/image.pdf", convert(&input)?).map_err(|e| e.to_string())
    })();
    match result { Ok(()) => 0, Err(e) => { eprintln!("{e}"); 1 } }
}

fn main() {
    let _ = log::set_logger(&DIAGNOSTICS); log::set_max_level(log::LevelFilter::Warn);
    let result = (|| {
        if std::env::args_os().len() != 1 { return Err("This compiler accepts SVG bytes on stdin, without file or network arguments".to_string()); }
        let mut input = Vec::new();
        std::io::stdin().take((MAX_BYTES + 1) as u64).read_to_end(&mut input).map_err(|e| e.to_string())?;
        let pdf = convert(&input)?;
        std::io::stdout().write_all(&pdf).map_err(|e| e.to_string())
    })();
    if let Err(error) = result { eprintln!("{}", error.chars().take(8000).collect::<String>()); std::process::exit(1); }
}

#[cfg(test)] mod tests {
    use super::*;
    #[test] fn external_and_foreign_content_is_explicitly_rejected() {
        for body in ["<foreignObject/>", "<image href='file:///private/x.png'/>", "<style>@import url(https://example.org/x.css);</style>"] {
            assert!(validate_svg(format!("<svg xmlns='http://www.w3.org/2000/svg'>{body}</svg>").as_bytes()).is_err());
        }
    }
    #[test] fn actual_engine_preserves_css_gradients_clipping_and_filters() {
        let source = br##"<svg xmlns="http://www.w3.org/2000/svg" width="200" height="100"><style>.paint{fill:url(#gradient)}</style><defs><linearGradient id="gradient"><stop stop-color="red"/><stop offset="1" stop-color="blue"/></linearGradient><clipPath id="clip"><circle cx="80" cy="50" r="40"/></clipPath><filter id="blur"><feGaussianBlur stdDeviation="2"/></filter></defs><rect class="paint" width="200" height="100" clip-path="url(#clip)" filter="url(#blur)"/></svg>"##;
        let result = convert(source).unwrap(); assert!(result.starts_with(b"%PDF-")); assert!(result.len() > 1000);
    }
    #[test] fn nested_svg_cannot_bypass_admission_with_a_sniffed_mime() {
        // This data URL contains <svg><foreignObject/></svg>. A declared SVG
        // and the default resolver's sniffed text/plain both fail explicitly.
        for mime in ["image/svg+xml", "text/plain"] {
            let source = format!("<svg xmlns='http://www.w3.org/2000/svg' width='20' height='20'><image width='20' height='20' href='data:{mime};base64,PHN2Zz48Zm9yZWlnbk9iamVjdC8+PC9zdmc+'/></svg>");
            assert!(convert(source.as_bytes()).is_err());
        }
    }
}
