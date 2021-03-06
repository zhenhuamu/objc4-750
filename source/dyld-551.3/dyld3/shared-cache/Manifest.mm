/*
 * Copyright (c) 2017 Apple Inc. All rights reserved.
 *
 * @APPLE_LICENSE_HEADER_START@
 *
 * This file contains Original Code and/or Modifications of Original Code
 * as defined in and that are subject to the Apple Public Source License
 * Version 2.0 (the 'License'). You may not use this file except in
 * compliance with the License. Please obtain a copy of the License at
 * http://www.opensource.apple.com/apsl/ and read it before using this
 * file.
 *
 * The Original Code and all software distributed under the License are
 * distributed on an 'AS IS' basis, WITHOUT WARRANTY OF ANY KIND, EITHER
 * EXPRESS OR IMPLIED, AND APPLE HEREBY DISCLAIMS ALL SUCH WARRANTIES,
 * INCLUDING WITHOUT LIMITATION, ANY WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE, QUIET ENJOYMENT OR NON-INFRINGEMENT.
 * Please see the License for the specific language governing rights and
 * limitations under the License.
 *
 * @APPLE_LICENSE_HEADER_END@
 */


extern "C" {
#include <Bom/Bom.h>
#include <Metabom/MBTypes.h>
#include <Metabom/MBEntry.h>
#include <Metabom/MBMetabom.h>
#include <Metabom/MBIterator.h>
};

#include <algorithm>
#include <CommonCrypto/CommonDigest.h>
#include <CommonCrypto/CommonDigestSPI.h>
#include <Foundation/Foundation.h>

#include "MachOFileAbstraction.hpp"
#include "FileAbstraction.hpp"
#include "Trie.hpp"
#include "FileUtils.h"
#include "StringUtils.h"

#include <mach-o/loader.h>
#include <mach-o/fat.h>

#include <array>
#include <vector>

#include "Manifest.h"

namespace {
//FIXME this should be in a class
static inline NSString* cppToObjStr(const std::string& str) { return [NSString stringWithUTF8String:str.c_str()]; }

template <class Set1, class Set2>
inline bool is_disjoint(const Set1& set1, const Set2& set2)
{
    if (set1.empty() || set2.empty())
        return true;

    typename Set1::const_iterator it1 = set1.begin(), it1End = set1.end();
    typename Set2::const_iterator it2 = set2.begin(), it2End = set2.end();

    if (*it1 > *set2.rbegin() || *it2 > *set1.rbegin())
        return true;

    while (it1 != it1End && it2 != it2End) {
        if (*it1 == *it2)
            return false;
        if (*it1 < *it2) {
            it1++;
        } else {
            it2++;
        }
    }

    return true;
}

//hACK: If we declare this in manifest
static NSDictionary* gManifestDict;

} /* Anonymous namespace */

namespace dyld3 {
void Manifest::Results::exclude(MachOParser* parser, const std::string& reason)
{
    auto dylibUUID = parser->uuid();
    dylibs[dylibUUID].uuid = dylibUUID;
    dylibs[dylibUUID].installname = parser->installName();
    dylibs[dylibUUID].included = false;
    dylibs[dylibUUID].exclusionInfo = reason;
}

void Manifest::Results::exclude(Manifest& manifest, const UUID& uuid, const std::string& reason)
{
    auto parser = manifest.parserForUUID(uuid);
    dylibs[uuid].uuid = uuid;
    dylibs[uuid].installname = parser.installName();
    dylibs[uuid].included = false;
    dylibs[uuid].exclusionInfo = reason;
}

Manifest::CacheImageInfo& Manifest::Results::dylibForInstallname(const std::string& installname)
{
    auto i = find_if(dylibs.begin(), dylibs.end(), [&installname](std::pair<UUID, CacheImageInfo> d) { return d.second.installname == installname; });
    assert(i != dylibs.end());
    return i->second;
}

bool Manifest::Architecture::operator==(const Architecture& O) const
{
    for (auto& dylib : results.dylibs) {
        if (dylib.second.included) {
            auto Odylib = O.results.dylibs.find(dylib.first);
            if (Odylib == O.results.dylibs.end()
                || Odylib->second.included == false
                || Odylib->second.uuid != dylib.second.uuid)
                return false;
        }
    }

    for (const auto& Odylib : O.results.dylibs) {
        if (Odylib.second.included) {
            auto dylib = results.dylibs.find(Odylib.first);
            if (dylib == results.dylibs.end()
                || dylib->second.included == false
                || dylib->second.uuid != Odylib.second.uuid)
                return false;
        }
    }

    for (auto& bundle : results.bundles) {
        if (bundle.second.included) {
            auto Obundle = O.results.bundles.find(bundle.first);
            if (Obundle == O.results.bundles.end()
                || Obundle->second.included == false
                || Obundle->second.uuid != bundle.second.uuid)
                return false;
        }
    }

    for (const auto& Obundle : O.results.bundles) {
        if (Obundle.second.included) {
            auto bundle = results.bundles.find(Obundle.first);
            if (bundle == results.bundles.end()
                || bundle->second.included == false
                || bundle->second.uuid != Obundle.second.uuid)
                return false;
        }
    }

    for (auto& executable : results.executables) {
        if (executable.second.included) {
            auto Oexecutable = O.results.executables.find(executable.first);
            if (Oexecutable == O.results.executables.end()
                || Oexecutable->second.included == false
                || Oexecutable->second.uuid != executable.second.uuid)
                return false;
        }
    }

    for (const auto& Oexecutable : O.results.executables) {
        if (Oexecutable.second.included) {
            auto executable = results.executables.find(Oexecutable.first);
            if (executable == results.executables.end()
                || executable->second.included == false
                || executable->second.uuid != Oexecutable.second.uuid)
                return false;
        }
    }

    return true;
}

bool Manifest::Configuration::operator==(const Configuration& O) const
{
    return architectures == O.architectures;
}

bool Manifest::Configuration::operator!=(const Configuration& other) const { return !(*this == other); }

const Manifest::Architecture& Manifest::Configuration::architecture(const std::string& architecture) const
{
    assert(architectures.find(architecture) != architectures.end());
    return architectures.find(architecture)->second;
}

void Manifest::Configuration::forEachArchitecture(std::function<void(const std::string& archName)> lambda) const
{
    for (const auto& architecutre : architectures) {
        lambda(architecutre.first);
    }
}

bool Manifest::Architecture::operator!=(const Architecture& other) const { return !(*this == other); }

const std::map<std::string, Manifest::Project>& Manifest::projects()
{
    return _projects;
}

const Manifest::Configuration& Manifest::configuration(const std::string& configuration) const
{
    assert(_configurations.find(configuration) != _configurations.end());
    return _configurations.find(configuration)->second;
}

void Manifest::forEachConfiguration(std::function<void(const std::string& configName)> lambda) const
{
    for (const auto& configuration : _configurations) {
        lambda(configuration.first);
    }
}

void Manifest::addProjectSource(const std::string& project, const std::string& source, bool first)
{
    auto& sources = _projects[project].sources;
    if (std::find(sources.begin(), sources.end(), source) == sources.end()) {
        if (first) {
            sources.insert(sources.begin(), source);
        } else {
            sources.push_back(source);
        }
    }
}

const std::string Manifest::projectPath(const std::string& projectName)
{
    auto project = _projects.find(projectName);
    if (project == _projects.end())
        return "";
    if (project->second.sources.size() == 0)
        return "";
    return project->second.sources[0];
}

const bool Manifest::empty(void)
{
    for (const auto& configuration : _configurations) {
        if (configuration.second.architectures.size() != 0)
            return false;
    }
    return true;
}

const std::string Manifest::dylibOrderFile() const { return _dylibOrderFile; };
void Manifest::setDylibOrderFile(const std::string& dylibOrderFile) { _dylibOrderFile = dylibOrderFile; };

const std::string Manifest::dirtyDataOrderFile() const { return _dirtyDataOrderFile; };
void Manifest::setDirtyDataOrderFile(const std::string& dirtyDataOrderFile) { _dirtyDataOrderFile = dirtyDataOrderFile; };

const std::string Manifest::metabomFile() const { return _metabomFile; };
void Manifest::setMetabomFile(const std::string& metabomFile) { _metabomFile = metabomFile; };

const Platform Manifest::platform() const { return _platform; };
void Manifest::setPlatform(const Platform platform) { _platform = platform; };

const std::string& Manifest::build() const { return _build; };
void Manifest::setBuild(const std::string& build) { _build = build; };
const uint32_t                             Manifest::version() const { return _manifestVersion; };
void Manifest::setVersion(const uint32_t manifestVersion) { _manifestVersion = manifestVersion; };

BuildQueueEntry Manifest::makeQueueEntry(const std::string& outputPath, const std::set<std::string>& configs, const std::string& arch, bool optimizeStubs, const std::string& prefix, bool verbose)
{
    dyld3::BuildQueueEntry retval;

    DyldSharedCache::CreateOptions options;
    options.archName = arch;
    options.platform = platform();
    options.excludeLocalSymbols = true;
    options.optimizeStubs = optimizeStubs;
    options.optimizeObjC = true;
    options.codeSigningDigestMode = (platform() == dyld3::Platform::watchOS) ?
                                    DyldSharedCache::Agile : DyldSharedCache::SHA256only;
    options.dylibsRemovedDuringMastering = true;
    options.inodesAreSameAsRuntime = false;
    options.cacheSupportsASLR = true;
    options.forSimulator = false;
    options.verbose = verbose;
    options.evictLeafDylibsOnOverflow = true;
    options.loggingPrefix = prefix;
    options.pathPrefixes = { "" };
    options.dylibOrdering = loadOrderFile(_dylibOrderFile);
    options.dirtyDataSegmentOrdering = loadOrderFile(_dirtyDataOrderFile);

    dyld3::BuildQueueEntry queueEntry;
    retval.configNames = configs;
    retval.options = options;
    retval.outputPath = outputPath;
    retval.dylibsForCache = dylibsForCache(*configs.begin(), arch);
    retval.otherDylibsAndBundles = otherDylibsAndBundles(*configs.begin(), arch);
    retval.mainExecutables = mainExecutables(*configs.begin(), arch);

    return retval;
}

bool Manifest::loadParser(const void* p, size_t size, uint64_t sliceOffset, const std::string& runtimePath, const std::string& buildPath, const std::set<std::string>& architectures)
{
    const mach_header* mh = reinterpret_cast<const mach_header*>(p);
    if (!MachOParser::isValidMachO(_diags, "", _platform, p, size, runtimePath.c_str(), false)) {
        return false;
    }

    auto parser = MachOParser(mh);
    if (_diags.hasError()) {
        // Clear the error and punt
        _diags.verbose("MachoParser error: %s\n", _diags.errorMessage().c_str());
        _diags.clearError();
        return false;
    }

    auto uuid = parser.uuid();
    auto archName = parser.archName();

    if (parser.fileType() == MH_DYLIB && architectures.count(parser.archName()) != 0) {
        std::string installName = parser.installName();
        auto index = std::make_pair(installName, parser.archName());
        auto i = _installNameMap.find(index);

        if ( installName == "/System/Library/Caches/com.apple.xpc/sdk.dylib"
            || installName == "/System/Library/Caches/com.apple.xpcd/xpcd_cache.dylib" ) {
            // HACK to deal with device specific dylibs. These must not be inseted into the installNameMap
            _uuidMap.insert(std::make_pair(uuid, UUIDInfo(mh, size, sliceOffset, uuid, parser.archName(), runtimePath, buildPath, installName)));
        } else if (i == _installNameMap.end()) {
            _installNameMap.insert(std::make_pair(index, uuid));
            _uuidMap.insert(std::make_pair(uuid, UUIDInfo(mh, size, sliceOffset, uuid, parser.archName(), runtimePath, buildPath, installName)));
            if (installName[0] != '@' && installName != runtimePath) {
                _diags.warning("Dylib located at '%s' has  installname '%s'", runtimePath.c_str(), installName.c_str());
            }
        } else {
            auto info = infoForUUID(i->second);
            _diags.warning("Multiple dylibs claim installname '%s' ('%s' and '%s')", installName.c_str(), runtimePath.c_str(), info.runtimePath.c_str());

            // This is the "Good" one, overwrite
            if (runtimePath == installName) {
                _uuidMap.erase(uuid);
                _uuidMap.insert(std::make_pair(uuid, UUIDInfo(mh, size, sliceOffset, uuid, parser.archName(), runtimePath, buildPath, installName)));
            }
        }
    } else {
        _uuidMap.insert(std::make_pair(uuid, UUIDInfo(mh, size, sliceOffset, uuid, parser.archName(), runtimePath, buildPath, "")));
    }
    return true;
}

//FIXME: assert we have not errored first
bool Manifest::loadParsers(const std::string& buildPath, const std::string& runtimePath, const std::set<std::string>& architectures)
{
    __block bool retval = false;
    const void*  p = (uint8_t*)(-1);
    struct stat  stat_buf;

    std::tie(p, stat_buf) = fileCache.cacheLoad(_diags, buildPath);

    if (p == (uint8_t*)(-1)) {
        return false;
    }

    if (FatUtil::isFatFile(p)) {
        FatUtil::forEachSlice(_diags, p, stat_buf.st_size, ^(uint32_t sliceCpuType, uint32_t sliceCpuSubType, const void* sliceStart, size_t sliceSize, bool& stop) {
            if (loadParser(sliceStart, sliceSize, (uintptr_t)sliceStart-(uintptr_t)p, runtimePath, buildPath, architectures))
                retval = true;
        });
    } else {
        return loadParser(p, stat_buf.st_size, 0, runtimePath, buildPath, architectures);
    }
    return retval;
}

const Manifest::UUIDInfo& Manifest::infoForUUID(const UUID& uuid) const {
    auto i = _uuidMap.find(uuid);
    assert(i != _uuidMap.end());
    return i->second;
}

const Manifest::UUIDInfo Manifest::infoForInstallNameAndarch(const std::string& installName, const std::string arch) const  {
    UUIDInfo retval;
    auto uuidI = _installNameMap.find(std::make_pair(installName, arch));
    if (uuidI == _installNameMap.end())
        return UUIDInfo();

    auto i = _uuidMap.find(uuidI->second);
    if (i == _uuidMap.end())
    return UUIDInfo();
    return i->second;
}

MachOParser Manifest::parserForUUID(const UUID& uuid) const {
    return MachOParser(infoForUUID(uuid).mh);
}

const std::string Manifest::buildPathForUUID(const UUID& uuid) {
    return infoForUUID(uuid).buildPath;
}

const std::string Manifest::runtimePathForUUID(const UUID& uuid) {
    return infoForUUID(uuid).runtimePath;
}
    
Manifest::Manifest(Diagnostics& D, const std::string& path)  : Manifest(D, path, std::set<std::string>())
{
}

Manifest::Manifest(Diagnostics& D, const std::string& path, const std::set<std::string>& overlays) :
    _diags(D)
{
    NSMutableDictionary* manifestDict = [NSMutableDictionary dictionaryWithContentsOfFile:cppToObjStr(path)];
    NSString*            platStr = manifestDict[@"platform"];
    std::set<std::string> architectures;

    if (platStr == nullptr)
        platStr = @"ios";
    std::string platformString = [platStr UTF8String];
    setMetabomFile([manifestDict[@"metabomFile"] UTF8String]);

    if (platformString == "ios") {
        setPlatform(dyld3::Platform::iOS);
    } else if ( (platformString == "tvos") || (platformString == "atv") ) {
        setPlatform(dyld3::Platform::tvOS);
    } else if ( (platformString == "watchos") || (platformString == "watch") ) {
        setPlatform(dyld3::Platform::watchOS);
    } else if ( (platformString == "bridgeos") || (platformString == "bridge") ) {
        setPlatform(dyld3::Platform::bridgeOS);
    } else if ( (platformString == "macos") || (platformString == "osx") ) {
        setPlatform(dyld3::Platform::macOS);
    } else {
        //Fixme should we error?
        setPlatform(dyld3::Platform::iOS);
    }

    for (NSString* project in manifestDict[@"projects"]) {
        for (NSString* source in manifestDict[@"projects"][project]) {
            addProjectSource([project UTF8String], [source UTF8String]);
        }
    }

    for (NSString* configuration in manifestDict[@"configurations"]) {
        std::string configStr = [configuration UTF8String];
        std::string configTag = [manifestDict[@"configurations"][configuration][@"metabomTag"] UTF8String];

        if (manifestDict[@"configurations"][configuration][@"metabomExcludeTags"]) {
            for (NSString* excludeTag in manifestDict[@"configurations"][configuration][@"metabomExcludeTags"]) {
                _metabomExcludeTagMap[configStr].insert([excludeTag UTF8String]);
                _configurations[configStr].metabomExcludeTags.insert([excludeTag UTF8String]);
            }
        }

        if (manifestDict[@"configurations"][configuration][@"metabomRestrictTags"]) {
            for (NSString* restrictTag in manifestDict[@"configurations"][configuration][@"metabomRestrictTags"]) {
                _metabomRestrictedTagMap[configStr].insert([restrictTag UTF8String]);
                _configurations[configStr].metabomRestrictTags.insert([restrictTag UTF8String]);
            }
        }

        _configurations[configStr].metabomTag = configTag;
        _configurations[configStr].metabomTags.insert(configTag);
        _configurations[configStr].platformName =
            [manifestDict[@"configurations"][configuration][@"platformName"] UTF8String];

        if (endsWith(configStr, "InternalOS")) {
            _configurations[configStr].disposition = "internal";
            _configurations[configStr].device = configStr.substr(0, configStr.length()-strlen("InternalOS"));
        } else if (endsWith(configStr, "VendorOS")) {
            _configurations[configStr].disposition = "internal";
            _configurations[configStr].device = configStr.substr(0, configStr.length()-strlen("VendorOS"));
        } else if (endsWith(configStr, "VendorUIOS")) {
            _configurations[configStr].disposition = "internal";
            _configurations[configStr].device = configStr.substr(0, configStr.length()-strlen("VendorUIOS"));
        } else if (endsWith(configStr, "CarrierOS")) {
            _configurations[configStr].disposition = "internal";
            _configurations[configStr].device = configStr.substr(0, configStr.length()-strlen("CarrierOS"));
        } else if (endsWith(configStr, "FactoryOS")) {
            _configurations[configStr].disposition = "internal";
            _configurations[configStr].device = configStr.substr(0, configStr.length()-strlen("FactoryOS"));
        } else if (endsWith(configStr, "DesenseOS")) {
            _configurations[configStr].disposition = "internal";
            _configurations[configStr].device = configStr.substr(0, configStr.length()-strlen("DesenseOS"));
        } else if (endsWith(configStr, "MinosOS")) {
            _configurations[configStr].disposition = "minos";
            _configurations[configStr].device = configStr.substr(0, configStr.length()-strlen("MinosOS"));
        } else if (endsWith(configStr, "DemoOS")) {
            _configurations[configStr].disposition = "demo";
            _configurations[configStr].device = configStr.substr(0, configStr.length()-strlen("DemoOS"));
        } else if (endsWith(configStr, "MinosOS")) {
            _configurations[configStr].disposition = "minos";
            _configurations[configStr].device = configStr.substr(0, configStr.length()-strlen("MinosOS"));
        } else if (endsWith(configStr, "DeveloperOS")) {
            _configurations[configStr].disposition = "user";
            _configurations[configStr].device = configStr.substr(0, configStr.length()-strlen("DeveloperOS"));
        } else if (endsWith(configStr, "OS")) {
            _configurations[configStr].disposition = "user";
            _configurations[configStr].device = configStr.substr(0, configStr.length()-strlen("OS"));
        }

        for (NSString* architecutre in manifestDict[@"configurations"][configuration][@"architectures"]) {
            //HACK until B&I stops mastering armv7s
            if ([architecutre isEqual:@"armv7s"]) break;
            _configurations[configStr].architectures[[architecutre UTF8String]] = Architecture();
            architectures.insert([architecutre UTF8String]);
        }
    }

    setVersion([manifestDict[@"manifest-version"] unsignedIntValue]);
    setBuild([manifestDict[@"build"] UTF8String]);
    if (manifestDict[@"dylibOrderFile"]) {
        setDylibOrderFile([manifestDict[@"dylibOrderFile"] UTF8String]);
    }
    if (manifestDict[@"dirtyDataOrderFile"]) {
        setDirtyDataOrderFile([manifestDict[@"dirtyDataOrderFile"] UTF8String]);
    }

    auto    metabom = MBMetabomOpen(metabomFile().c_str(), false);
    auto    metabomEnumerator = MBIteratorNewWithPath(metabom, ".", "");
    MBEntry entry;

    // FIXME error handling (NULL metabom)

    //First we iterate through the bom and build our objects

    while ((entry = MBIteratorNext(metabomEnumerator))) {
        BOMFSObject  fsObject = MBEntryGetFSObject(entry);
        BOMFSObjType entryType = BOMFSObjectType(fsObject);
        std::string  entryPath = BOMFSObjectPathName(fsObject);
        if (entryPath[0] == '.') {
            entryPath.erase(0, 1);
        }

        // Skip artifacts that happen to be in the build chain
        if ( startsWith(entryPath, "/Applications/Xcode.app") ) {
            continue;
        }

        // Skip variants we can't deal with
        if ( endsWith(entryPath, "_profile.dylib") || endsWith(entryPath, "_debug.dylib") || endsWith(entryPath, "_profile") || endsWith(entryPath, "_debug") || endsWith(entryPath, "/CoreADI") ) {
            continue;
        }

        // Skip images that are only used in InternalOS variants
        if ( startsWith(entryPath, "/AppleInternal/") || startsWith(entryPath, "/usr/local/") || startsWith(entryPath, "/Developer/")) {
            continue;
        }
        
        // Skip genCache generated dylibs
        if ( endsWith(entryPath, "/System/Library/Caches/com.apple.xpc/sdk.dylib") || endsWith(entryPath, "/System/Library/Caches/com.apple.xpcd/xpcd_cache.dylib")) {
            continue;
        }

        MBTag tag;
        auto  tagCount = MBEntryGetNumberOfProjectTags(entry);
        if (entryType == BOMFileType && BOMFSObjectIsBinaryObject(fsObject) && MBEntryGetNumberOfProjectTags(entry) != 0 && tagCount != 0) {
            if (tagCount == 1) {
                MBEntryGetProjectTags(entry, &tag);
            } else {
                MBTag* tags = (MBTag*)malloc(sizeof(MBTag) * tagCount);
                MBEntryGetProjectTags(entry, tags);

                //Sigh, we can have duplicate entries for the same tag, so build a set to work with
                std::set<std::string> tagStrs;
                std::map<std::string, MBTag> tagStrMap;
                for (auto i = 0; i < tagCount; ++i) {
                    tagStrs.insert(MBMetabomGetProjectForTag(metabom, tags[i]));
                    tagStrMap.insert(std::make_pair(MBMetabomGetProjectForTag(metabom, tags[i]), tags[i]));
                }

                if (tagStrs.size() > 1) {
                    std::string projects;
                    for (const auto& tagStr : tagStrs) {
                        if (!projects.empty())
                            projects += ", ";

                        projects += "'" + tagStr + "'";
                    }
                    _diags.warning("Bom entry '%s' is claimed by multiple projects: %s, taking first entry", entryPath.c_str(), projects.c_str());
                }
                tag = tagStrMap[*tagStrs.begin()];
                free(tags);
            }

            std::string projectName = MBMetabomGetProjectForTag(metabom, tag);
            tagCount = MBEntryGetNumberOfPackageTags(entry);
            MBTag* tags = (MBTag*)malloc(sizeof(MBTag) * tagCount);
            MBEntryGetPackageTags(entry, tags);
            std::set<std::string> tagStrs;

            for (auto i = 0; i < tagCount; ++i) {
                tagStrs.insert(MBMetabomGetPackageForTag(metabom, tags[i]));
            }

            _metabomTagMap.insert(std::make_pair(entryPath, tagStrs));
            bool foundParser = false;
            for (const auto& overlay : overlays) {
                if (loadParsers(overlay + "/" + entryPath, entryPath, architectures)) {
                    foundParser = true;
                    break;
                }
            }

            if (!foundParser) {
                (void)loadParsers(projectPath(projectName) + "/" + entryPath, entryPath, architectures);
            }
        }
    }

    MBIteratorFree(metabomEnumerator);
    MBMetabomFree(metabom);
}

void Manifest::insert(std::vector<DyldSharedCache::MappedMachO>& mappedMachOs, const CacheImageInfo& imageInfo) {
    auto info = infoForUUID(imageInfo.uuid);
    auto runtimePath = info.runtimePath;
    mappedMachOs.emplace_back(runtimePath, info.mh, info.size, false, false, info.sliceFileOffset, 0, 0);
}

std::vector<DyldSharedCache::MappedMachO> Manifest::dylibsForCache(const std::string& configuration, const std::string& architecture)
{
    std::vector<DyldSharedCache::MappedMachO> retval;
    const auto&                               dylibs = _configurations[configuration].architectures[architecture].results.dylibs;
    for (const auto& dylib : dylibs) {
        if (dylib.second.included) {
            insert(retval, dylib.second);
        }
    }
    return retval;
}

std::vector<DyldSharedCache::MappedMachO> Manifest::otherDylibsAndBundles(const std::string& configuration, const std::string& architecture)
{
    std::vector<DyldSharedCache::MappedMachO> retval;
    const auto&                               dylibs = _configurations[configuration].architectures[architecture].results.dylibs;
    for (const auto& dylib : dylibs) {
        if (!dylib.second.included) {
            insert(retval, dylib.second);
        }
    }

    const auto& bundles = _configurations[configuration].architectures[architecture].results.bundles;
    for (const auto& bundle : bundles) {
        insert(retval, bundle.second);
    }

    return retval;
}

std::vector<DyldSharedCache::MappedMachO> Manifest::mainExecutables(const std::string& configuration, const std::string& architecture)
{
    std::vector<DyldSharedCache::MappedMachO> retval;
    const auto&                               executables = _configurations[configuration].architectures[architecture].results.executables;
    for (const auto& executable : executables) {
        insert(retval, executable.second);
    }

    return retval;
}

bool Manifest::filterForConfig(const std::string& configName)
{
    for (const auto configuration : _configurations) {
        if (configName == configuration.first) {
            std::map<std::string, Configuration> filteredConfigs;
            filteredConfigs[configName] = configuration.second;

            _configurations = filteredConfigs;

            for (auto& arch : configuration.second.architectures) {
                arch.second.results = Manifest::Results();
            }
            return true;
        }
    }
    return false;
}

void Manifest::dedupeDispositions(void) {
    // Since this is all hacky and inference based for now only do it for iOS until XBS
    // is reved to give us real info. All the other platforms are way smaller anyway.
    if (_platform != Platform::iOS)
        return;

    std::map<std::pair<std::string, std::string>, std::set<std::string>> dispositionSets;

    for (const auto& configuration : _configurations) {
        dispositionSets[std::make_pair(configuration.second.device, configuration.second.disposition)].insert(configuration.first);
    }

    for (const auto& dSet : dispositionSets) {
        for (const auto &c1 : dSet.second) {
            for (const auto &c2 : dSet.second) {
                _configurations[c1].metabomTags.insert(_configurations[c2].metabomTag);
            }
        }
    }
}

void Manifest::calculateClosure()
{
    auto closureSemaphore = dispatch_semaphore_create(32);
    auto closureGroup = dispatch_group_create();
    auto closureQueue = dispatch_queue_create("com.apple.dyld.cache.closure", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_CONCURRENT, QOS_CLASS_USER_INITIATED, 0));

    dedupeDispositions();
    for (auto& config : _configurations) {
        for (auto& arch : config.second.architectures) {
            dispatch_semaphore_wait(closureSemaphore, DISPATCH_TIME_FOREVER);
            dispatch_group_async(closureGroup, closureQueue, [&] {
                calculateClosure(config.first, arch.first);
                dispatch_semaphore_signal(closureSemaphore);
            });
        }
    }

    dispatch_group_wait(closureGroup, DISPATCH_TIME_FOREVER);
}

void Manifest::remove(const std::string& config, const std::string& arch)
{
    if (_configurations.count(config))
        _configurations[config].architectures.erase(arch);
}

void Manifest::removeDylib(MachOParser parser, const std::string& reason, const std::string& configuration,
    const std::string& architecture, std::unordered_set<UUID>& processedIdentifiers)
{
#if 0
    auto configIter = _configurations.find(configuration);
    if (configIter == _configurations.end())
        return;
    auto archIter = configIter->second.architectures.find( architecture );
    if ( archIter == configIter->second.architectures.end() ) return;
    auto& archManifest = archIter->second;

    if (archManifest.results.dylibs.count(parser->uuid()) == 0) {
        archManifest.results.dylibs[parser->uuid()].uuid = parser->uuid();
        archManifest.results.dylibs[parser->uuid()].installname = parser->installName();
        processedIdentifiers.insert(parser->uuid());
    }
    archManifest.results.exclude(MachOProxy::forIdentifier(parser->uuid(), architecture), reason);

    processedIdentifiers.insert(parser->uuid());

    for (const auto& dependent : proxy->dependentIdentifiers) {
        auto dependentProxy = MachOProxy::forIdentifier(dependent, architecture);
        auto dependentResultIter = archManifest.results.dylibs.find(dependentProxy->identifier);
        if ( dependentProxy &&
             ( dependentResultIter == archManifest.results.dylibs.end() || dependentResultIter->second.included == true ) ) {
            removeDylib(dependentProxy, "Missing dependency: " + proxy->installName, configuration, architecture,
                processedIdentifiers);
        }
    }
#endif
}

const std::string Manifest::removeLargestLeafDylib(const std::set<std::string>& configurations, const std::string& architecture)
{
    // Find the leaf nodes
    __block std::map<std::string, uint64_t> dependentCounts;
    for (const auto& dylib : _configurations[*configurations.begin()].architectures[architecture].results.dylibs) {
        if (!dylib.second.included)
            continue;
        std::string installName;
        auto info = infoForUUID(dylib.first);
        auto parser = MachOParser(info.mh);
        dependentCounts[parser.installName()] = 0;
    }

    for (const auto& dylib : _configurations[*configurations.begin()].architectures[architecture].results.dylibs) {
        if (!dylib.second.included)
            continue;
        auto info = infoForUUID(dylib.first);
        auto parser = MachOParser(info.mh);
        parser.forEachDependentDylib(^(const char *loadPath, bool isWeak, bool isReExport, bool isUpward, uint32_t compatVersion, uint32_t curVersion, bool &stop) {
            if (!isWeak) {
                dependentCounts[loadPath]++;
            }
        });
    }

    // Figure out which leaf is largest
    UUIDInfo largestLeaf;

    for (const auto& dependentCount : dependentCounts) {
        if (dependentCount.second == 0) {
            auto info = infoForInstallNameAndarch(dependentCount.first, architecture);
            assert(info.mh != nullptr);
            if (info.size > largestLeaf.size) {
                largestLeaf = info;
            }
        }
    }

    if (largestLeaf.mh == nullptr) {
        _diags.error("Fatal overflow, could not evict more dylibs");
        return "";
    }

    // Remove it ferom all configs
    for (const auto& config : configurations) {
        configuration(config).architecture(architecture).results.exclude(*this, largestLeaf.uuid, "Cache Overflow");
    }

    return largestLeaf.installName;
}

void Manifest::calculateClosure(const std::string& configuration, const std::string& architecture)
{
    __block auto&   configManifest = _configurations[configuration];
    __block auto&   archManifest = _configurations[configuration].architectures[architecture];
    __block std::set<UUID> newUuids;
    std::set<UUID>         processedUuids;
    std::set<UUID>         cachedUUIDs;

    // Seed anchors
    for (auto& uuidInfo : _uuidMap) {
        auto info = uuidInfo.second;
        if (info.arch != architecture) {
            continue;
        }

        auto i = _metabomTagMap.find(info.runtimePath);
        assert(i != _metabomTagMap.end());
        auto tags = i->second;
        if (!is_disjoint(tags, configManifest.metabomTags)) {
            newUuids.insert(info.uuid);

        }
    }

    // Pull in all dependencies
    while (!newUuids.empty()) {
        std::set<UUID> uuidsToProcess = newUuids;
        newUuids.clear();

        for (const auto& uuid : uuidsToProcess) {
            if (processedUuids.count(uuid) > 0) {
                continue;
            }
            processedUuids.insert(uuid);

            auto parser = parserForUUID(uuid);
            auto runtimePath = runtimePathForUUID(uuid);
            assert(parser.header() != 0);

            parser.forEachDependentDylib(^(const char* loadPath, bool isWeak, bool isReExport, bool isUpward, uint32_t compatVersion, uint32_t curVersion, bool& stop) {
                auto i = _installNameMap.find(std::make_pair(loadPath, architecture));
                if (i != _installNameMap.end())
                newUuids.insert(i->second);
            });

            if (parser.fileType() == MH_DYLIB) {
                // Add the dylib to the results
                if (archManifest.results.dylibs.count(uuid) == 0 ) {
                    archManifest.results.dylibs[uuid].uuid = uuid;
                    archManifest.results.dylibs[uuid].installname = parser.installName();
                }

                // HACK to insert device specific dylib closures into all caches
                if ( parser.installName() == std::string("/System/Library/Caches/com.apple.xpc/sdk.dylib")
                    || parser.installName() == std::string("/System/Library/Caches/com.apple.xpcd/xpcd_cache.dylib") ) {
                    archManifest.results.exclude(&parser, "Device specific dylib");
                    continue;
                }

                std::set<std::string> reasons;
                if (parser.canBePlacedInDyldCache(runtimePath, reasons)) {
                    auto i = _metabomTagMap.find(runtimePath);
                    assert(i != _metabomTagMap.end());
                    auto restrictions = _metabomRestrictedTagMap.find(configuration);
                    if (restrictions != _metabomRestrictedTagMap.end() && !is_disjoint(restrictions->second, i->second)) {
                        archManifest.results.exclude(&parser, "Dylib '" + runtimePath + "' removed due to explict restriction");
                    }

                    // It can be placed in the cache, grab its dependents and queue them for inclusion
                    cachedUUIDs.insert(parser.uuid());
                } else {
                    // It can't be placed in the cache, print out the reasons why
                    std::string reasonString = "Rejected from cached dylibs: " + runtimePath + " " + architecture + " (\"";
                    for (auto i = reasons.begin(); i != reasons.end(); ++i) {
                        reasonString += *i;
                        if (i != --reasons.end()) {
                            reasonString += "\", \"";
                        }
                    }
                    reasonString += "\")";
                    archManifest.results.exclude(&parser, reasonString);
                }
            } else if (parser.fileType() == MH_BUNDLE) {
                if (archManifest.results.bundles.count(uuid) == 0) {
                    archManifest.results.bundles[uuid].uuid = uuid;
                }
            } else if (parser.fileType() == MH_EXECUTE) {
                //HACK exclude all launchd and installd variants until we can do something about xpcd_cache.dylib and friends
                if (runtimePath == "/sbin/launchd"
                    || runtimePath == "/usr/local/sbin/launchd.debug"
                    || runtimePath == "/usr/local/sbin/launchd.development"
                    || runtimePath == "/usr/libexec/installd") {
                    continue;
                }
                if (archManifest.results.executables.count(uuid) == 0) {
                    archManifest.results.executables[uuid].uuid = uuid;
                }
            }
        }
    }

    __block std::set<UUID>         removedUUIDs;
    __block bool                   doAgain = true;

    //Trim out dylibs that are missing dependencies
    while ( doAgain ) {
        doAgain = false;
        for (const auto& uuid : cachedUUIDs) {
            __block std::set<std::string> badDependencies;
            __block auto parser = parserForUUID(uuid);
            parser.forEachDependentDylib(^(const char* loadPath, bool isWeak, bool isReExport, bool isUpward, uint32_t compatVersion, uint32_t curVersion, bool& stop) {
                if (isWeak)
                    return;

                auto i = _installNameMap.find(std::make_pair(loadPath, architecture));
                if (i == _installNameMap.end() || removedUUIDs.count(i->second)) {
                    removedUUIDs.insert(uuid);
                    badDependencies.insert(loadPath);
                    doAgain = true;
                }

                if (badDependencies.size()) {
                    std::string reasonString = "Rejected from cached dylibs: " + std::string(parser.installName()) + " " + architecture + " (\"";
                    for (auto i = badDependencies.begin(); i != badDependencies.end(); ++i) {
                        reasonString += *i;
                        if (i != --badDependencies.end()) {
                            reasonString += "\", \"";
                        }
                    }
                    reasonString += "\")";
                    archManifest.results.exclude(&parser, reasonString);
                }
            });
        }

        for (const auto& removedUUID : removedUUIDs) {
            cachedUUIDs.erase(removedUUID);
        }
    }

    //Trim out excluded leaf dylibs
    __block std::set<std::string> linkedDylibs;

    for(const auto& uuid : cachedUUIDs) {
        auto parser = parserForUUID(uuid);
        parser.forEachDependentDylib(^(const char* loadPath, bool isWeak, bool isReExport, bool isUpward, uint32_t compatVersion, uint32_t curVersion, bool& stop) {
            linkedDylibs.insert(loadPath);
        });
    }

    for(const auto& uuid : cachedUUIDs) {
        auto info = infoForUUID(uuid);
        auto i = _metabomTagMap.find(info.runtimePath);
        assert(i != _metabomTagMap.end());
        auto exclusions = _metabomExcludeTagMap.find(configuration);
        if (exclusions == _metabomExcludeTagMap.end() || is_disjoint(exclusions->second, i->second))
            continue;

        if (linkedDylibs.count(info.installName) != 0)
            continue;

        archManifest.results.exclude(*this, info.uuid, "Dylib '" + info.runtimePath + "' excluded leaf node");
    }
}

void Manifest::writeJSON(const std::string& path) {
    NSMutableDictionary* jsonDict = [[NSMutableDictionary alloc] init];
    for (auto& configuration : _configurations) {
        jsonDict[cppToObjStr(configuration.first)] = [[NSMutableDictionary alloc] init];

        for (auto& arch : configuration.second.architectures) {
            NSMutableOrderedSet* includedDylibsSet = [[NSMutableOrderedSet alloc] init];
            NSMutableOrderedSet* executablesSet = [[NSMutableOrderedSet alloc] init];
            NSMutableOrderedSet* otherSet = [[NSMutableOrderedSet alloc] init];
            for (auto& dylib : arch.second.results.dylibs) {
                NSString *runtimePath = cppToObjStr(runtimePathForUUID(dylib.second.uuid));
                if (dylib.second.included) {
                    [includedDylibsSet addObject:runtimePath];
                } else {
                    [otherSet addObject:runtimePath];
                }
            }

            for (auto& executable : arch.second.results.executables) {
                NSString *runtimePath = cppToObjStr(runtimePathForUUID(executable.second.uuid));
                [executablesSet addObject:runtimePath];
            }

            for (auto& bundle : arch.second.results.bundles) {
                NSString *runtimePath = cppToObjStr(runtimePathForUUID(bundle.second.uuid));
                [otherSet addObject:runtimePath];
            }

            [includedDylibsSet sortUsingComparator:^NSComparisonResult(id  _Nonnull obj1, id  _Nonnull obj2) {
                return [obj1 compare:obj2];
            }];

            [executablesSet sortUsingComparator:^NSComparisonResult(id  _Nonnull obj1, id  _Nonnull obj2) {
                return [obj1 compare:obj2];
            }];

            [otherSet sortUsingComparator:^NSComparisonResult(id  _Nonnull obj1, id  _Nonnull obj2) {
                return [obj1 compare:obj2];
            }];

            jsonDict[cppToObjStr(configuration.first)][cppToObjStr(arch.first)] = @{ @"cachedDylibs" : [includedDylibsSet array], @"mainExecutables" : [executablesSet array], @"other" : [otherSet array]};;
        }
    }

    NSError* error = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:jsonDict options:0x0 error:&error];
    (void)[jsonData writeToFile:cppToObjStr(path) atomically:YES];
}

void Manifest::write(const std::string& path)
{
    if (path.empty())
        return;

    NSMutableDictionary* cacheDict = [[NSMutableDictionary alloc] init];
    NSMutableDictionary* projectDict = [[NSMutableDictionary alloc] init];
    NSMutableDictionary* configurationsDict = [[NSMutableDictionary alloc] init];
    NSMutableDictionary* resultsDict = [[NSMutableDictionary alloc] init];

    cacheDict[@"manifest-version"] = @(version());
    cacheDict[@"build"] = cppToObjStr(build());
    cacheDict[@"dylibOrderFile"] = cppToObjStr(dylibOrderFile());
    cacheDict[@"dirtyDataOrderFile"] = cppToObjStr(dirtyDataOrderFile());
    cacheDict[@"metabomFile"] = cppToObjStr(metabomFile());

    cacheDict[@"projects"] = projectDict;
    cacheDict[@"results"] = resultsDict;
    cacheDict[@"configurations"] = configurationsDict;

    for (const auto& project : projects()) {
        NSMutableArray* sources = [[NSMutableArray alloc] init];

        for (const auto& source : project.second.sources) {
            [sources addObject:cppToObjStr(source)];
        }

        projectDict[cppToObjStr(project.first)] = sources;
    }

    for (auto& configuration : _configurations) {
        NSMutableArray* archArray = [[NSMutableArray alloc] init];
        for (auto& arch : configuration.second.architectures) {
            [archArray addObject:cppToObjStr(arch.first)];
        }

        NSMutableArray* excludeTags = [[NSMutableArray alloc] init];
        for (const auto& excludeTag : configuration.second.metabomExcludeTags) {
            [excludeTags addObject:cppToObjStr(excludeTag)];
        }

        configurationsDict[cppToObjStr(configuration.first)] = @{
            @"platformName" : cppToObjStr(configuration.second.platformName),
            @"metabomTag" : cppToObjStr(configuration.second.metabomTag),
            @"metabomExcludeTags" : excludeTags,
            @"architectures" : archArray
        };
    }

    for (auto& configuration : _configurations) {
        NSMutableDictionary* archResultsDict = [[NSMutableDictionary alloc] init];
        for (auto& arch : configuration.second.architectures) {
            NSMutableDictionary* dylibsDict = [[NSMutableDictionary alloc] init];
            NSMutableArray* warningsArray = [[NSMutableArray alloc] init];
            NSMutableDictionary* devRegionsDict = [[NSMutableDictionary alloc] init];
            NSMutableDictionary* prodRegionsDict = [[NSMutableDictionary alloc] init];
            NSString* prodCDHash = cppToObjStr(arch.second.results.productionCache.cdHash);
            NSString* devCDHash = cppToObjStr(arch.second.results.developmentCache.cdHash);

            for (auto& dylib : arch.second.results.dylibs) {
                NSMutableDictionary* dylibDict = [[NSMutableDictionary alloc] init];
                if (dylib.second.included) {
                    dylibDict[@"included"] = @YES;
                } else {
                    dylibDict[@"included"] = @NO;
                    dylibDict[@"exclusionInfo"] = cppToObjStr(dylib.second.exclusionInfo);
                }
                dylibsDict[cppToObjStr(dylib.second.installname)] = dylibDict;
            }

            for (auto& warning : arch.second.results.warnings) {
                [warningsArray addObject:cppToObjStr(warning)];
            }

            BOOL built = arch.second.results.failure.empty();
            archResultsDict[cppToObjStr(arch.first)] = @{
                @"dylibs" : dylibsDict,
                @"built" : @(built),
                @"failure" : cppToObjStr(arch.second.results.failure),
                @"productionCache" : @{ @"cdhash" : prodCDHash, @"regions" : prodRegionsDict },
                @"developmentCache" : @{ @"cdhash" : devCDHash, @"regions" : devRegionsDict },
                @"warnings" : warningsArray
            };
        }
        resultsDict[cppToObjStr(configuration.first)] = archResultsDict;
    }

    switch (platform()) {
    case Platform::iOS:
        cacheDict[@"platform"] = @"ios";
        break;
    case Platform::tvOS:
        cacheDict[@"platform"] = @"tvos";
        break;
    case Platform::watchOS:
        cacheDict[@"platform"] = @"watchos";
        break;
    case Platform::bridgeOS:
        cacheDict[@"platform"] = @"bridgeos";
        break;
    case Platform::macOS:
        cacheDict[@"platform"] = @"macos";
        break;
    case Platform::unknown:
        cacheDict[@"platform"] = @"unknown";
        break;
    }

    NSError* error = nil;
    NSData*  outData = [NSPropertyListSerialization dataWithPropertyList:cacheDict
                                                                 format:NSPropertyListBinaryFormat_v1_0
                                                                options:0
                                                                  error:&error];
    (void)[outData writeToFile:cppToObjStr(path) atomically:YES];
}
}
