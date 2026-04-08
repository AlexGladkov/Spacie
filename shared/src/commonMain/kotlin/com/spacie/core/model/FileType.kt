package com.spacie.core.model

import kotlin.experimental.ExperimentalObjCName
import kotlin.native.ObjCName

@OptIn(ExperimentalObjCName::class)
@ObjCName("SpaFileType")
enum class FileType(val code: Int) {
    VIDEO(0),
    AUDIO(1),
    IMAGE(2),
    DOCUMENT(3),
    ARCHIVE(4),
    CODE(5),
    APPLICATION(6),
    SYSTEM(7),
    OTHER(8);

    val displayName: String
        get() = when (this) {
            VIDEO -> "Video"
            AUDIO -> "Audio"
            IMAGE -> "Images"
            DOCUMENT -> "Documents"
            ARCHIVE -> "Archives"
            CODE -> "Code"
            APPLICATION -> "Applications"
            SYSTEM -> "System"
            OTHER -> "Other"
        }

    companion object {
        fun fromExtension(ext: String): FileType {
            return when (ext.lowercase()) {
                // Video
                "mp4", "mov", "avi", "mkv", "wmv", "flv", "webm", "m4v", "mpg", "mpeg",
                "3gp", "3g2", "mts", "m2ts", "vob", "ogv", "rm", "rmvb", "f4v", "mxf",
                "r3d", "asf", "dv", "divx", "ts" -> VIDEO

                // Audio
                "mp3", "wav", "aac", "flac", "ogg", "wma", "m4a", "aiff", "opus",
                "mid", "midi", "ape", "wv", "caf", "dsf", "dff", "ac3", "dts",
                "amr", "au", "ra", "spx", "mka", "pcm", "snd",
                "m4b", "m4p", "aax", "m4r" -> AUDIO

                // Images -- photos, RAW camera formats, design files
                "jpg", "jpeg", "png", "gif", "bmp", "tiff", "tif", "webp", "svg",
                "heic", "heif", "raw", "ico", "psd",
                "avif", "jxl", "jp2", "jfif",
                // Camera RAW
                "cr2", "cr3", "nef", "nrw", "dng", "arw", "orf", "rw2", "raf",
                "pef", "x3f", "3fr", "srw", "rwl", "kdc", "dcr", "mrw", "erf",
                // Design & illustration
                "ai", "eps", "indd", "xcf", "sketch", "afdesign", "afphoto",
                // HDR & specialized
                "exr", "hdr", "tga", "dds", "icns", "cur", "pbm", "pgm", "ppm" -> IMAGE

                // Documents
                "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "rtf",
                "pages", "numbers", "keynote", "odt", "ods", "odp", "csv",
                "epub", "mobi", "azw", "azw3", "djvu", "fb2", "cbr", "cbz",
                "md", "tex", "rst", "org", "wps", "wpd",
                "ics", "vcf", "eml", "msg", "mbox" -> DOCUMENT

                // Archives
                "zip", "rar", "7z", "tar", "gz", "bz2", "xz", "dmg", "iso", "pkg", "deb", "rpm",
                "tgz", "tbz2", "txz", "zst", "lz", "lzma", "lz4", "sz", "cab", "cpio",
                "jar", "war", "ear", "apk", "ipa", "whl", "egg", "gem", "crx",
                "snap", "flatpak", "nupkg", "vsix",
                // macOS disk images & VM formats
                "sparseimage", "sparsebundle",
                "vmdk", "qcow2", "vdi", "vhd", "vhdx", "ova", "ovf" -> ARCHIVE

                // Code & development
                "swift", "m", "h", "c", "cpp", "cc", "cxx", "hpp", "hxx",
                "py", "pyw", "pyx", "pxd",
                "js", "mjs", "cjs", "jsx", "tsx",
                "java", "kt", "kts", "rs", "go", "rb", "erb",
                "html", "htm", "css", "scss", "sass", "less", "styl",
                "json", "xml", "yaml", "yml", "toml", "ini", "cfg", "conf",
                "sh", "zsh", "bash", "fish", "ps1", "psm1", "bat", "cmd",
                "sql", "r", "lua", "dart", "scala", "php", "pl", "pm",
                "ex", "exs", "hs", "lhs", "ml", "mli", "fs", "fsx", "fsi",
                "clj", "cljs", "cljc", "edn", "elm", "purs",
                "zig", "nim", "v", "cr", "jl", "groovy", "gradle",
                "vue", "svelte", "graphql", "gql", "proto",
                "tf", "hcl", "cmake", "makefile", "mk",
                "dockerfile", "vagrantfile",
                "ipynb", "wasm", "wat", "map",
                "xcodeproj", "xcworkspace", "pbxproj", "storyboard", "xib", "nib",
                "lock", "editorconfig", "gitignore", "gitattributes",
                "env", "properties", "sbt", "cabal", "podspec",
                "gemspec", "csproj", "sln", "vcxproj",
                "o", "a", "d", "hmap", "modulemap", "swiftmodule", "swiftdoc",
                "class", "pyc", "pyo", "elc", "beam" -> CODE

                // Applications & frameworks
                "app", "framework", "dylib", "so", "dll", "exe", "msi",
                "bundle", "plugin", "kext", "prefpane",
                "xpc", "appex", "qlgenerator", "mdimporter", "saver",
                "action", "workflow", "shortcut",
                "vst", "vst3", "component", "audiounit" -> APPLICATION

                // System & configuration
                "plist", "log", "crash", "ips",
                "db", "sqlite", "sqlite3", "realm",
                "wal", "shm", "journal",
                "cache", "tmp", "temp", "bak", "old", "orig", "swp",
                "keychain", "provisionprofile", "mobileprovision",
                "cer", "crt", "pem", "key", "p12", "pfx",
                "car", "actool", "storedata", "mom", "momd", "omo",
                "strings", "stringsdict", "lproj",
                "data", "dat", "bin",
                "ttf", "otf", "woff", "woff2", "ttc", "dfont",
                "metallib", "gpurc" -> SYSTEM

                else -> OTHER
            }
        }

        fun fromContext(path: String): FileType {
            // Fast path: system binary/library paths
            if (path.startsWith("/usr/") || path.startsWith("/bin/")
                || path.startsWith("/sbin/") || path.startsWith("/System/")
                || path.startsWith("/Library/Apple/")
            ) {
                return SYSTEM
            }
            // Package bundle check: only run if path contains a dot
            if (path.contains(".")) {
                if (path.contains(".app/") || path.contains(".framework/")
                    || path.contains(".bundle/") || path.contains(".plugin/")
                    || path.contains(".kext/") || path.contains(".xpc/")
                    || path.contains(".appex/") || path.contains(".prefpane/")
                    || path.contains(".saver/") || path.contains(".qlgenerator/")
                    || path.contains(".mdimporter/")
                ) {
                    return APPLICATION
                }
            }
            return OTHER
        }
    }
}
