/*
 * This file is part of moss-deps.
 *
 * Copyright © 2020-2021 Serpent OS Developers
 *
 * This software is provided 'as-is', without any express or implied
 * warranty. In no event will the authors be held liable for any damages
 * arising from the use of this software.
 *
 * Permission is granted to anyone to use this software for any purpose,
 * including commercial applications, and to alter it and redistribute it
 * freely, subject to the following restrictions:
 *
 * 1. The origin of this software must not be misrepresented; you must not
 *    claim that you wrote the original software. If you use this software
 *    in a product, an acknowledgment in the product documentation would be
 *    appreciated but is not required.
 * 2. Altered source versions must be plainly marked as such, and must not be
 *    misrepresented as being the original software.
 * 3. This notice may not be removed or altered from any source distribution.
 */

module moss.deps.analysis.elves;

import elf : ELF, ELF64, ELFSection, DynamicLinkingTable, ElfNote;
import std.string : format, fromStringz, startsWith;
import std.exception : enforce;
import std.algorithm : each, canFind, count;
import std.path : baseName, dirName, buildPath;
import std.stdio : stderr, File;
import std.file : exists;

public import moss.deps.dependency;
public import moss.deps.analysis.chain;

import std.stdint : uint32_t;

/**
 * Used to match the first 4 bytes of files
 */
static private immutable ubyte[4] elfMagic = [0x7f, 0x45, 0x4c, 0x46];

/**
 * Store BuildID as string
 */
public const AttributeBuildID = "BuildID";

/**
 * Store bitsize (32 or 64)
 */
public const AttributeBitSize = "BitSize";

private static bool isElfFile(in string fullPath) @trusted
{
    auto fi = File(fullPath, "rb");
    scope (exit)
    {
        fi.close();
    }
    /* Need at least a 16-byte file */
    if (fi.size() < 16)
    {
        return false;
    }

    /* Check the magic */
    ubyte[4] elfBuffer = [0, 0, 0, 0];
    const auto firstBytes = fi.rawRead(elfBuffer);
    if (firstBytes != elfMagic)
    {
        return false;
    }

    /* Legit looks like an ELF file */
    return true;
}

/**
 * This function will return "NextFunction" if the input file is a valid ELF
 * file. Otherwise, it will simply return "NextHandler".
 */
public AnalysisReturn acceptElfFiles(scope Analyser analyser, ref FileInfo fileInfo)
{
    if (fileInfo.type == FileType.Regular && isElfFile(fileInfo.fullPath))
    {
        return AnalysisReturn.NextFunction;
    }

    return AnalysisReturn.NextHandler;
}

/**
 * Assuming the input is a valid ELF file, i.e. from using acceptElfFiles, we
 * can scan the binary for any dependencies (DT_NEEDED) and provided SONAME.
 */
public AnalysisReturn scanElfFiles(scope Analyser analyser, ref FileInfo fileInfo)
{
    auto fi = ELF.fromFile(fileInfo.fullPath);

    bool has64 = ((cast(ELF64) fi) !is null);
    fileInfo.bitSize = has64 ? 64 : 32;

    foreach (section; fi.sections)
    {
        switch (section.name)
        {
        case ".interp":
            /* Extract DT_INTERP, program interpreter */
            auto dtInterp = cast(char[]) section.contents;
            auto dtInterpSz = fromStringz(dtInterp.ptr);
            auto d = Dependency("%s(%s)".format(dtInterpSz,
                    fi.header.machineISA), DependencyType.Interpreter);
            analyser.bucket(fileInfo).addDependency(d);
            break;
        case ".dynamic":
            /* Extract DT_NEEDED, shared library dependencies */
            auto dynTable = DynamicLinkingTable(section);
            dynTable.needed.each!((r) {
                auto dtNeeded = "%s(%s)".format(r, fi.header.machineISA);
                auto d = Dependency(dtNeeded, DependencyType.SharedLibraryName);
                analyser.bucket(fileInfo).addDependency(d);
            });

            /* Soname exposed? Lets share it. */
            /* TODO: Only expose ACTUAL libraries */
            auto soname = dynTable.soname;
            if (soname == "" || !fileInfo.fullPath.canFind(".so"))
            {
                break;
            }
            auto sonameProvider = "%s(%s)".format(soname, fi.header.machineISA);
            auto p = Provider(sonameProvider, ProviderType.SharedLibraryName);
            analyser.bucket(fileInfo).addProvider(p);

            /* Do we possibly have an Interpeter? This is a .dynamic library .. */
            auto localName = soname.baseName;
            if (localName.startsWith("ld-") && fileInfo.path.count('/') == 3
                    && fileInfo.path.startsWith("/usr/lib"))
            {
                string[] interpPaths = [];

                /* 64-bit file */
                if (has64)
                {
                    interpPaths = [
                        "/usr/lib64/%s(%s)".format(localName, fi.header.machineISA),
                        "/lib64/%s(%s)".format(localName, fi.header.machineISA),
                        "/lib/%s(%s)".format(localName, fi.header.machineISA),
                        "%s(%s)".format(fileInfo.path, fi.header.machineISA)
                    ];
                }
                else
                {
                    interpPaths = [
                        "/usr/lib/%s(%s)".format(localName, fi.header.machineISA),
                        "/lib/%s(%s)".format(localName, fi.header.machineISA),
                        "/lib32/%s(%s)".format(localName, fi.header.machineISA),
                        "%s(%s)".format(fileInfo.path, fi.header.machineISA)
                    ];
                }

                /* Add interpreter + soname providers now */
                foreach (pname; interpPaths)
                {
                    auto pInterp = Provider(pname, ProviderType.Interpreter);
                    auto pSoname = Provider(pname, ProviderType.SharedLibraryName);
                    analyser.bucket(fileInfo).addProvider(pInterp);
                    analyser.bucket(fileInfo).addProvider(pSoname);
                }
            }
            break;
        case ".note.gnu.build-id":
            auto note = ElfNote(section);
            import std.digest : toHexString, LetterCase;

            /* Look like a proper build id to us? NT_GNU_BUILD_ID = 3 */
            if (note.type == 3 && note.name == "GNU")
            {
                enforce(note.descriptor.length == 8 || note.descriptor.length == 20);
                fileInfo.buildID = note.descriptor.toHexString!(LetterCase.lower)();
            }

            break;
        default:
            break;
        }
    }
    return AnalysisReturn.NextFunction;
}

unittest
{
    import std.file : thisExePath;
    import moss.deps.analysis.analyser : Analyser;

    auto ourname = thisExePath;

    auto fi = FileInfo(ourname, ourname);
    auto rule = AnalysisChain("elves", [
            &acceptElfFiles, &scanElfFiles, &includeFile
            ]);
    fi.target = "main";
    auto an = new Analyser();
    an.addFile(fi);
    an.addChain(rule);
    an.process();

    import std.stdio : writeln;

    auto deps = an.bucket("main").dependencies;
    assert(!deps.empty, "Cannot find dependenies for this test");
    writeln(deps);

}
