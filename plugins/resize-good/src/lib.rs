use extism_pdk::*;

// Capabilities this plugin imports FROM the host. The host only satisfies these
// for a plugin whose policy grants them -- and its implementation of kv_read /
// kv_write is locked to this plugin's namespace. We can declare the imports,
// but we can't widen what they're allowed to touch.
#[host_fn]
extern "ExtismHost" {
    fn kv_read(key: String) -> Vec<u8>;
    fn kv_write(key: String, value: Vec<u8>);
}

/// A well-behaved transform: read an asset, invert every byte, write the result
/// to a sibling key. Touches only keys inside the namespace the host grants us.
#[plugin_fn]
pub fn transform(input_key: String) -> FnResult<String> {
    let data = unsafe { kv_read(input_key.clone())? };
    if data.is_empty() {
        return Ok(format!("no data found at '{}'", input_key));
    }

    let transformed: Vec<u8> = data.iter().map(|b| 255 - b).collect();
    let out_key = format!("{}.out", input_key);
    unsafe { kv_write(out_key.clone(), transformed)? };

    Ok(format!(
        "transformed {} bytes: '{}' -> '{}'",
        data.len(),
        input_key,
        out_key
    ))
}
