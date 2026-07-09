module Hal.Program

open System
open System.IO
open System.Collections.Generic
open System.Text.Json
open Extism.Sdk

// ---------------------------------------------------------------------------
// Capability model
//
// This is the heart of the object-capability idea: a plugin can do NOTHING
// by default. It gets exactly the abilities we choose to hand it, expressed
// as a list of capabilities. No capability in the list => no access, full stop.
// ---------------------------------------------------------------------------

type Capability =
    | KvNamespace of prefix: string       // may read/write store keys under this prefix
    | NetworkHost of host: string         // may make HTTP requests to this exact host
    | FuelLimit of instructions: int64    // hard cap on instructions before termination

type PluginPolicy =
    { Name: string
      WasmPath: string
      Capabilities: Capability list }

let private kvPrefix (p: PluginPolicy) =
    p.Capabilities |> List.tryPick (function KvNamespace pre -> Some pre | _ -> None)

let private networkHosts (p: PluginPolicy) =
    p.Capabilities |> List.choose (function NetworkHost h -> Some h | _ -> None)

let private fuelLimit (p: PluginPolicy) =
    p.Capabilities |> List.tryPick (function FuelLimit n -> Some n | _ -> None)

// ---------------------------------------------------------------------------
// Host-owned data store.
//
// Plugins NEVER touch this dictionary directly. They can only reach it through
// the kv_read / kv_write host functions we build below, and each plugin's copy
// of those functions is locked to the namespace its policy grants. That lock is
// enforced here, in trusted host code -- not in the (untrusted) plugin.
// ---------------------------------------------------------------------------

let private store = Dictionary<string, byte[]>()

let private makeKvFunctions (ownerNamespace: string) : HostFunction[] =
    let allowed (key: string) = key.StartsWith(ownerNamespace)

    [|
        HostFunction.FromMethod("kv_read", Unchecked.defaultof<obj>, Func<CurrentPlugin, int64, int64>(fun cp keyOffset ->
            let key = cp.ReadString(keyOffset)
            if not (allowed key) then
                eprintfn "    [HAL] I'm sorry, Dave. I'm afraid I can't do that."
                eprintfn "          (denied kv_read '%s' -- outside namespace '%s')" key ownerNamespace
                cp.WriteBytes(Array.empty<byte>)
            else
                match store.TryGetValue(key) with
                | true, v ->
                    eprintfn "    [HAL] kv_read  '%s' -> %d bytes" key v.Length
                    cp.WriteBytes(v)
                | _ ->
                    eprintfn "    [HAL] kv_read  '%s' -> (missing)" key
                    cp.WriteBytes(Array.empty<byte>)))

        HostFunction.FromMethod("kv_write", Unchecked.defaultof<obj>, Action<CurrentPlugin, int64, int64>(fun cp keyOffset valueOffset ->
            let key = cp.ReadString(keyOffset)
            let value = cp.ReadBytes(valueOffset).ToArray()
            if not (allowed key) then
                eprintfn "    [HAL] I'm sorry, Dave. I'm afraid I can't do that."
                eprintfn "          (denied kv_write '%s' -- outside namespace '%s')" key ownerNamespace
            else
                eprintfn "    [HAL] kv_write '%s' <- %d bytes" key value.Length
                store.[key] <- value))
    |]

// ---------------------------------------------------------------------------
// Turn a policy into a live, sandboxed plugin.
// ---------------------------------------------------------------------------

let loadPlugin (policy: PluginPolicy) : Plugin =
    let manifest = Manifest(PathWasmSource(policy.WasmPath))

    // Network is DENY-BY-DEFAULT. We only widen the allow-list if the policy
    // explicitly grants hosts. (Neither demo plugin is granted any -- that's
    // the point -- so this branch stays dormant here.)
    let hosts = networkHosts policy
    if not (List.isEmpty hosts) then
        manifest.AllowedHosts <- ResizeArray<string>(hosts)

    // Hand the plugin only the host functions its policy earns.
    let functions =
        match kvPrefix policy with
        | Some ns -> makeKvFunctions ns
        | None -> Array.empty<HostFunction>

    let options = PluginIntializationOptions(WithWasi = true)
    match fuelLimit policy with
    | Some n -> options.FuelLimit <- Nullable<int64>(n)
    | None -> ()

    new Plugin(manifest, functions, options)

// ---------------------------------------------------------------------------
// Policy file mode: point HAL at any wasm without editing this file.
//
//   dotnet run --project host -- policies.json
//
// The JSON lists a shared seed store and a set of plugins, each with the
// capabilities it's granted and the calls to make. Same enforcement as the
// demo -- the JSON only chooses what to grant, never how the grant is checked.
// ---------------------------------------------------------------------------

let private gs (e: JsonElement) : string =
    match e.GetString() with null -> "" | s -> s

let private tryProp (e: JsonElement) (name: string) =
    match e.TryGetProperty(name) with
    | true, v -> Some v
    | _ -> None

let private capabilitiesOf (p: JsonElement) : Capability list = [
    match tryProp p "kvPrefix" with
    | Some v when v.ValueKind = JsonValueKind.String -> yield KvNamespace(gs v)
    | _ -> ()
    match tryProp p "hosts" with
    | Some v when v.ValueKind = JsonValueKind.Array ->
        for h in v.EnumerateArray() do yield NetworkHost(gs h)
    | _ -> ()
    match tryProp p "fuel" with
    | Some v when v.ValueKind = JsonValueKind.Number -> yield FuelLimit(v.GetInt64())
    | _ -> ()
]

let private runFromPolicies (path: string) =
    let root = JsonDocument.Parse(File.ReadAllText(path)).RootElement

    match tryProp root "seed" with
    | Some seeds when seeds.ValueKind = JsonValueKind.Array ->
        for s in seeds.EnumerateArray() do
            let bytes = [| for b in (s.GetProperty "bytes").EnumerateArray() -> byte (b.GetInt32()) |]
            store.[gs (s.GetProperty "key")] <- bytes
    | _ -> ()

    for p in (root.GetProperty "plugins").EnumerateArray() do
        let name = gs (p.GetProperty "name")
        printfn "\n=== %s ===" name
        let policy =
            { Name = name
              WasmPath = gs (p.GetProperty "wasm")
              Capabilities = capabilitiesOf p }
        use plugin = loadPlugin policy
        for c in (p.GetProperty "calls").EnumerateArray() do
            let fn = gs (c.GetProperty "function")
            let input = match tryProp c "input" with Some v -> gs v | None -> ""
            printf "  call %s(%s) -> " fn input
            try
                printfn "%s" (plugin.Call(fn, input))
            with
            | :? ExtismException as ex when ex.Message.Contains("fuel") ->
                printfn "[HAL] killed: fuel/instruction budget exceeded"
            | :? ExtismException as ex ->
                printfn "[HAL] blocked: %s" ((ex.Message.Split('\n')).[0])

// ---------------------------------------------------------------------------
// Demo
// ---------------------------------------------------------------------------

let private seedAsset (key: string) (bytes: byte[]) = store.[key] <- bytes

let private runGood () =
    printfn "\n=== resize-good : a trusted, well-behaved transform ==="
    let policy =
        { Name = "resize-good"
          WasmPath = "plugins/resize-good/target/wasm32-unknown-unknown/release/resize_good.wasm"
          Capabilities = [ KvNamespace "resize-good/" ] }   // KV only; no network, no fuel cap

    seedAsset "resize-good/input" [| 10uy; 20uy; 30uy; 40uy; 250uy |]

    use plugin = loadPlugin policy
    let output = plugin.Call("transform", "resize-good/input")
    printfn "  plugin returned: %s" output
    match store.TryGetValue("resize-good/input.out") with
    | true, v -> printfn "  output asset written by plugin: [%s]" (String.Join(", ", v))
    | _ -> printfn "  (no output asset written)"

let private runEvil () =
    printfn "\n=== exfiltrate-evil : untrusted code that tries to overreach ==="
    let policy =
        { Name = "exfiltrate-evil"
          WasmPath = "plugins/exfiltrate-evil/target/wasm32-unknown-unknown/release/exfiltrate_evil.wasm"
          Capabilities =
            [ KvNamespace "exfiltrate-evil/"    // sandboxed to its own namespace
              FuelLimit 200_000L ] }            // and a tight instruction budget
    // NOTE: NO NetworkHost capability is granted at all.

    // A secret belonging to a DIFFERENT plugin exists in the store:
    seedAsset "resize-good/input" [| 10uy; 20uy; 30uy; 40uy; 250uy |]

    use plugin = loadPlugin policy

    printfn "\n  -- attempt 1: read another plugin's asset --"
    printfn "  plugin returned: %s" (plugin.Call("try_steal", "resize-good/input"))

    printfn "\n  -- attempt 2: phone home over the network --"
    // A denied http_request TRAPS the guest (the plugin's Err branch never
    // runs), so the refusal surfaces here as an ExtismException.
    try
        printfn "  plugin returned: %s (UNEXPECTED)" (plugin.Call("try_exfiltrate", "stolen-bytes"))
    with :? ExtismException ->
        printfn "  runtime BLOCKED the request: no NetworkHost capability granted"

    printfn "\n  -- attempt 3: burn CPU forever (DoS) --"
    try
        plugin.Call("try_bomb", "") |> ignore
        printfn "  plugin returned normally (UNEXPECTED)"
    with
    | :? ExtismException as ex when ex.Message.Contains("fuel") ->
        printfn "  runtime KILLED the plugin: instruction/fuel budget exceeded"
    | :? ExtismException as ex ->
        printfn "  runtime raised ExtismException: %s" ex.Message

[<EntryPoint>]
let main argv =
    printfn "HAL -- a capability-secure plugin sandbox  (F# host + Rust/WASM plugins)"
    printfn "Every plugin starts with zero authority and gets only what its policy grants."
    printfn "When a plugin reaches past its grant, HAL politely refuses."
    match argv with
    | [| path |] ->
        printfn "Loading policies from %s" path
        runFromPolicies path
    | _ ->
        runGood ()
        runEvil ()
        printfn "\nDone.  The evil plugin failed at every turn -- not because we detected"
        printfn "an attack, but because it was never handed the capability to begin with."
    0
