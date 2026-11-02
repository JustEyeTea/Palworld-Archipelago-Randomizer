// Dumps Palworld's region and biome trigger actors (BP_PalRegionTrigger*, BP_PalBiomeTrigger*) from the main world's
// cells with CUE4Parse, for tools/area_walls.py. The output is Pocketpair's data: keep it out of this repository.
//   dotnet run -- <Paks dir> <mappings .usmap> <oodle library> <raw_dump.json>
//   python -I process.py <raw_dump.json> <all-tables dir> <out dir>   (writes regions.json and regions.png)
using System.Text;
using CUE4Parse.Compression;
using CUE4Parse.FileProvider;
using CUE4Parse.MappingsProvider.Usmap;
using CUE4Parse.UE4.Assets.Exports;
using CUE4Parse.UE4.Versions;
using Newtonsoft.Json;
using CUE4Parse.UE4.Objects.UObject;
using Newtonsoft.Json.Linq;

var pakDir = args[0]; var usmap = args[1]; var oodle = args[2]; var outPath = args[3];
OodleHelper.Initialize(oodle);
var provider = new DefaultFileProvider(pakDir, SearchOption.TopDirectoryOnly, true, new VersionContainer(EGame.GAME_UE5_1));
provider.MappingsContainer = new FileUsmapTypeMappingsProvider(usmap, StringComparer.OrdinalIgnoreCase);
provider.Initialize();
provider.Mount();
Console.Error.WriteLine($"files: {provider.Files.Count}");

var outObj = new JObject();
var bps = new JObject();
foreach (var f in provider.Files.Keys.Where(k => k.Contains("/RegionAndBiome/", StringComparison.OrdinalIgnoreCase) && k.EndsWith(".uasset")).OrderBy(k => k)) {
    var pkg = provider.LoadPackage(f);
    var arr = new JArray();
    foreach (var e in pkg.GetExports()) arr.Add(JToken.FromObject(Ser(e)));
    bps[f] = arr;
}
outObj["blueprints"] = bps;

var needle = Encoding.ASCII.GetBytes("RegionAndBiome");
var maps = provider.Files.Keys.Where(k => k.Contains("/Maps/", StringComparison.OrdinalIgnoreCase) && k.EndsWith(".umap")).OrderBy(k => k).ToList();
Console.Error.WriteLine($"umaps: {maps.Count}");
var actors = new JArray(); int hit = 0, n = 0;
foreach (var f in maps) {
    if (++n % 2000 == 0) Console.Error.WriteLine($"{n}/{maps.Count} hits={hit}");
    byte[] raw;
    try { raw = provider.SaveAsset(f); } catch (Exception ex) { Console.Error.WriteLine($"read fail {f}: {ex.Message}"); continue; }
    if (raw.AsSpan().IndexOf(needle) < 0) continue;
    hit++;
    try {
        var pkg = provider.LoadPackage(f);
        var exports = pkg.GetExports().ToList();
        foreach (var e in exports) {
            var cls = e.Class?.Name.Text ?? "";
            if (!(cls.Contains("Trigger") && (cls.StartsWith("BP_Pal") || cls.StartsWith("BP_Biome")))) continue;
            var comps = new JArray();
            foreach (var c in exports) if (c.Outer != null && c.Outer.Name.Text == e.Name) comps.Add(JToken.FromObject(Ser(c)));
            actors.Add(new JObject { ["package"] = f, ["name"] = e.Name, ["path"] = e.GetPathName(), ["class"] = cls, ["actor"] = JToken.FromObject(Ser(e)), ["components"] = comps });
        }
    } catch (Exception ex) { Console.Error.WriteLine($"load fail {f}: {ex}"); }
}
outObj["actors"] = actors;
File.WriteAllText(outPath, outObj.ToString(Formatting.Indented));
Console.Error.WriteLine($"done: {hit} packages, {actors.Count} actors");

static object Ser(UObject o, int depth = 0) {
    var j = JObject.Parse(JsonConvert.SerializeObject(o));
    if (depth < 4) {
        try { var t = o.Template?.Load(); if (t != null) j["_TemplateObj"] = JToken.FromObject(Ser(t, 4)); } catch (Exception ex) { j["_TemplateErr"] = ex.Message; }
        try {
            if (o.TryGetValue(out FPackageIndex ap, "AttachParent") && !ap.IsNull) {
                var po = ap.ResolvedObject?.Load();
                if (po != null && po.Outer?.Name.Text != o.Outer?.Name.Text) { j["_AttachParentObj"] = JToken.FromObject(Ser(po, depth + 1)); j["_AttachParentOuter"] = po.Outer?.Name.Text; }
            }
        } catch (Exception ex) { j["_AttachErr"] = ex.Message; }
    }
    j["_Outer"] = o.Outer?.Name.Text; j["_Class"] = o.Class?.Name.Text; j["_Template"] = o.Template?.Name.ToString();
    return j;
}
