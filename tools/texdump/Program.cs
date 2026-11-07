// Exports Palworld textures to PNG, keeping their folders.
//   texdump <pakDir> <usmap> <oodle dll> <outDir> <item>...
// An item is a package path ("Pal/Content/Pal/Texture/UI/Title/T_title_BG") or a folder ending in "/" (every texture
// under it). A package that is not a texture lists the textures and materials it imports instead. If the Oodle DLL is
// missing, CUE4Parse downloads it into the current folder first.
using CUE4Parse.Compression;
using CUE4Parse.FileProvider;
using CUE4Parse.MappingsProvider.Usmap;
using CUE4Parse.UE4.Assets.Exports.Texture;
using CUE4Parse.UE4.Versions;
using CUE4Parse_Conversion.Textures;
using CUE4Parse_Conversion;
using CUE4Parse_Conversion.Options;
using CUE4Parse_Conversion.Formats;
var pakDir = args[0]; var usmap = args[1]; var oodle = args[2]; var outDir = args[3];
if (!File.Exists(oodle)) { OodleHelper.DownloadOodleDllAsync().GetAwaiter().GetResult(); oodle = new[] { OodleHelper.OODLE_NAME_CURRENT, OodleHelper.OODLE_NAME_OLD }.FirstOrDefault(File.Exists) ?? oodle; }
OodleHelper.Initialize(oodle);
var provider = new DefaultFileProvider(pakDir, SearchOption.TopDirectoryOnly, true, new VersionContainer(EGame.GAME_UE5_1));
provider.MappingsContainer = new FileUsmapTypeMappingsProvider(usmap, StringComparer.OrdinalIgnoreCase);
provider.Initialize(); provider.Mount();
var paths = new List<string>();
foreach (var item in args.Skip(4)) {
    if (!item.EndsWith("/")) { paths.Add(item); continue; }
    var found = provider.Files.Keys.Where(k => k.StartsWith(item, StringComparison.OrdinalIgnoreCase) && k.EndsWith(".uasset"))
        .Select(k => k[..^7]).OrderBy(k => k).ToList();
    Console.WriteLine($"{item}: {found.Count} packages"); paths.AddRange(found);
}
int ok = 0, bad = 0;
foreach (var path in paths) {
    try {
        var pkg = provider.LoadPackage(path);
        var tex = pkg.GetExports().OfType<UTexture2D>().FirstOrDefault();
        if (tex == null) {
            if (paths.Count > 1 && args.Any(a => a.EndsWith("/") && path.StartsWith(a, StringComparison.OrdinalIgnoreCase))) continue;
            Console.WriteLine($"{path}: not a texture; uses:");
            if (pkg is CUE4Parse.UE4.Assets.Package p2) foreach (var i in p2.ImportMap)
                if (i.ClassName.Text.Contains("Texture") || i.ClassName.Text.Contains("Material")) Console.WriteLine("  " + i.ClassName.Text + " " + i.ObjectName.Text);
            continue;
        }
        if (tex.PlatformData?.Mips == null || tex.PlatformData.Mips.Length == 0) { Console.WriteLine($"{path}: no pixel data (server build?)"); bad++; continue; }
        var c = tex.Decode();
        var file = Path.Combine(outDir, path.Replace("Pal/Content/Pal/", "").Replace('/', Path.DirectorySeparatorChar) + ".png");
        Directory.CreateDirectory(Path.GetDirectoryName(file));
        File.WriteAllBytes(file, c.Encode(ETextureFormat.Png, false, out _));
        Console.WriteLine($"{path}: {c.Width}x{c.Height}"); ok++;
    } catch (Exception ex) { Console.WriteLine($"{path}: FAIL {ex.GetType().Name} {ex.Message}"); bad++; }
}
Console.WriteLine($"done: {ok} exported, {bad} failed");
