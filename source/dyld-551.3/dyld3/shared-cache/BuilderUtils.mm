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


#include <set>
#include <string>
#include <sstream>
#include <iomanip> // std::setfill, std::setw
#include <pthread.h>
#include <mach/mach.h>
#include <dispatch/dispatch.h>

#include <Bom/Bom.h>
#include <Security/Security.h>
#include <Security/SecCodeSigner.h>
#include <CommonCrypto/CommonCrypto.h>

#include "Manifest.h"
#include "Diagnostics.h"
#include "FileUtils.h"

#include "BuilderUtils.h"

static dispatch_queue_t write_queue = dispatch_queue_create("com.apple.dyld.cache-builder.write", DISPATCH_QUEUE_CONCURRENT);
static dispatch_group_t build_group = dispatch_group_create();

dispatch_group_t buildGroup() {
    return build_group;
}

void insertFileInBom(const std::string& path, BOMBom bom)
{
    std::vector<std::string> components;
    std::vector<std::string> processed_components;
    std::stringstream ss(path);
    std::string item;

    while (std::getline(ss, item, '/')) {
        if (!item.empty()) {
            components.push_back(item);
        }
    }

    std::string partialPath = ".";
    std::string lastComponent = components.back();
    components.pop_back();
    BOMFSObject fso = BOMFSObjectNew(BOMDirectoryType);
    BOMFSObjectSetFlags(fso, B_PATHONLY);
    BOMFSObjectSetPathName(fso, ".", true);
    BOMFSObjectSetShortName(fso, ".", true);
    (void)BOMBomInsertFSObject(bom, fso, false);
    BOMFSObjectFree(fso);

    for (const auto& component : components) {
        partialPath = partialPath + "/" + component;
        fso = BOMFSObjectNew(BOMDirectoryType);
        BOMFSObjectSetFlags(fso, B_PATHONLY);
        BOMFSObjectSetPathName(fso, partialPath.c_str(), true);
        BOMFSObjectSetShortName(fso, component.c_str(), true);
        (void)BOMBomInsertFSObject(bom, fso, false);
        BOMFSObjectFree(fso);
    }

    partialPath = partialPath + "/" + lastComponent;
    fso = BOMFSObjectNew(BOMFileType);
    BOMFSObjectSetFlags(fso, B_PATHONLY);
    BOMFSObjectSetPathName(fso, partialPath.c_str(), true);
    BOMFSObjectSetShortName(fso, lastComponent.c_str(), true);
    (void)BOMBomInsertFSObject(bom, fso, false);
    BOMFSObjectFree(fso);
}

void makeBoms(dyld3::Manifest& manifest, const std::string& masterDstRoot)
{
    mkpath_np((masterDstRoot + "/Boms/").c_str(), 0755);

    manifest.forEachConfiguration([&manifest, &masterDstRoot](const std::string& configName) {
        auto                     config = manifest.configuration(configName);
        std::vector<std::string> prodBomPaths;
        std::vector<std::string> devBomPaths;

        std::string runtimePath =  "/System/Library/Caches/com.apple.dyld/";
        if (manifest.platform() == dyld3::Platform::macOS) {
            runtimePath =  "/private/var/db/dyld/";
        }

        for (auto& arch : config.architectures) {
            std::string cachePath = "dyld_shared_cache_" + arch.first;
            prodBomPaths.push_back(cachePath);
            if (manifest.platform() != dyld3::Platform::macOS) {
                cachePath += ".development";
            }
            devBomPaths.push_back(cachePath);
            char buffer[MAXPATHLEN];
            sprintf(buffer, "%s/Boms/%s.prod.bom", masterDstRoot.c_str(), configName.c_str());
            BOMBom bom = BOMBomNew(buffer);
            for (auto& path : prodBomPaths) {
                insertFileInBom(runtimePath + path, bom);
            }
            BOMBomFree(bom);

            sprintf(buffer, "%s/Boms/%s.dev.bom", masterDstRoot.c_str(), configName.c_str());
            bom = BOMBomNew(buffer);
            for (auto& path : devBomPaths) {
                insertFileInBom(runtimePath + path, bom);
            }
            BOMBomFree(bom);
            
            sprintf(buffer, "%s/Boms/%s.full.bom", masterDstRoot.c_str(), configName.c_str());
            bom = BOMBomNew(buffer);
            for (auto& path : prodBomPaths) {
                insertFileInBom(runtimePath + path, bom);
            }
            for (auto& path : devBomPaths) {
                insertFileInBom(runtimePath + path, bom);
            }
            BOMBomFree(bom);
        }
    });
}

bool build(Diagnostics& diags, dyld3::Manifest& manifest, const std::string& masterDstRoot, bool dedupe, bool verbose,
           bool skipWrites, bool agileChooseSHA256CdHash)
{
    dispatch_queue_t                   queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
    dispatch_queue_t                   warningQueue = dispatch_queue_create("com.apple.dyld.cache-builder.warnings", DISPATCH_QUEUE_SERIAL);
    std::vector<std::set<std::string>> dedupedCacheSets;
    if (dedupe) {
        manifest.forEachConfiguration([&manifest, &dedupedCacheSets](const std::string& configName) {
            auto config = manifest.configuration(configName);
            bool dupeFound = false;
            
            for (auto& cacheSet : dedupedCacheSets) {
                if (config == manifest.configuration(*cacheSet.begin())) {
                    cacheSet.insert(configName);
                    dupeFound = true;
                    break;
                }
            }
            
            if (!dupeFound) {
                std::set<std::string> temp;
                temp.insert(configName);
                dedupedCacheSets.push_back(temp);
            }
        });
    } else {
        manifest.forEachConfiguration([&manifest, &dedupedCacheSets](const std::string& configName) {
            std::set<std::string> temp;
            temp.insert(configName);
            dedupedCacheSets.push_back(temp);
        });
    }
    
    std::vector<dyld3::BuildQueueEntry> buildQueue;
    
    for (auto& cacheSet : dedupedCacheSets) {
        //FIXME we may want to consider moving to hashes of UUID sets
        std::string setName;
        
        for (auto& archName : cacheSet) {
            if (!setName.empty()) {
                setName += "|";
            }
            setName += archName;
        }
        
        std::stringstream fileNameStream;
        std::array<uint8_t, CC_SHA1_DIGEST_LENGTH> digest = { 0 };
        CC_SHA1(setName.c_str(), (unsigned int)setName.length(), &digest[0]);
        
        fileNameStream << std::hex << std::uppercase << std::setfill('0');
        for (int c : digest) {
            fileNameStream << std::setw(2) << c;
        }
        
        std::string fileName(fileNameStream.str());
        
        if (dedupe) {
            for (auto& config : cacheSet) {
                if (!skipWrites) {
                    int err = symlink(("DedupedConfigs/" + fileName).c_str(), (masterDstRoot + "/" + config).c_str());
                    if (err) {
                        diags.warning("Could not create symlink '%s' -> 'DedupedConfigs/%s' (%d)", config.c_str(), fileName.c_str(), err);
                    }
                }
            }
        }
        
        manifest.configuration(*cacheSet.begin()).forEachArchitecture([&masterDstRoot, &dedupe, &fileName, &setName, &manifest, &buildQueue, &cacheSet, verbose](const std::string& arch) {
            std::string configPath;
            std::string runtimePath =  "/System/Library/Caches/com.apple.dyld/";
            if (manifest.platform() == dyld3::Platform::macOS) {
                runtimePath =  "/private/var/db/dyld/";
            }
            if (dedupe) {
                configPath = masterDstRoot + "/DedupedConfigs/" + fileName + runtimePath;
            } else {
                configPath = masterDstRoot + runtimePath;
            }

            if (manifest.platform() == dyld3::Platform::macOS) {
                buildQueue.push_back(manifest.makeQueueEntry(configPath + "dyld_shared_cache_" + arch, cacheSet, arch, false, setName + "/" + arch, verbose));
            } else {
                buildQueue.push_back(manifest.makeQueueEntry(configPath + "dyld_shared_cache_" + arch + ".development", cacheSet, arch, false, setName + "/" + arch, verbose));
                buildQueue.push_back(manifest.makeQueueEntry(configPath + "dyld_shared_cache_" + arch, cacheSet, arch, true, setName + "/" + arch, verbose));
            }
        });
    }

    __block bool cacheBuildFailure = false;
    __block std::set<std::string> warnings;
    __block std::set<std::string> errors;

    dispatch_sync(warningQueue, ^{
        auto manifestWarnings = diags.warnings();
        warnings.insert(manifestWarnings.begin(), manifestWarnings.end());
    });

    dispatch_apply(buildQueue.size(), queue, ^(size_t index) {
        auto queueEntry = buildQueue[index];
        pthread_setname_np(queueEntry.options.loggingPrefix.substr(0, MAXTHREADNAMESIZE - 1).c_str());
        
        DyldSharedCache::CreateResults results = DyldSharedCache::create(queueEntry.options, queueEntry.dylibsForCache, queueEntry.otherDylibsAndBundles, queueEntry.mainExecutables);
        dispatch_sync(warningQueue, ^{
            warnings.insert(results.warnings.begin(), results.warnings.end());
            bool chooseSecondCdHash = agileChooseSHA256CdHash;
            if (agileChooseSHA256CdHash && !results.agileSignature) {
                // Ignore this option for caches that are not signed agile (which is the majority).
                chooseSecondCdHash = false;
            }
            for (const auto& configName : queueEntry.configNames) {
                auto& configResults = manifest.configuration(configName).architecture(queueEntry.options.archName).results;
                for (const auto& mh : results.evictions) {
                    auto parser = dyld3::MachOParser(mh);
                    configResults.exclude(&parser, "VM overflow, evicting");
                }
                configResults.warnings = results.warnings;
                if (queueEntry.options.optimizeStubs) {
                    configResults.developmentCache.cdHash = chooseSecondCdHash ? results.cdHashSecond : results.cdHashFirst;
                } else {
                    configResults.productionCache.cdHash =  chooseSecondCdHash ? results.cdHashSecond : results.cdHashFirst;
                }
            }
        });
        if (!results.errorMessage.empty()) {
            fprintf(stderr, "[%s] ERROR: %s\n", queueEntry.options.loggingPrefix.c_str(), results.errorMessage.c_str());
        } else if (!skipWrites) {
            dispatch_sync(write_queue, ^{
                // save new cache file to disk and write new .map file
                assert(results.cacheContent != nullptr);
                mkpath_np(dirPath(queueEntry.outputPath).c_str(), 0755);
                if (!safeSave(results.cacheContent, results.cacheLength, queueEntry.outputPath)) {
                    cacheBuildFailure = true;
                    fprintf(stderr, "[%s] ERROR: Could not write cache to: %s\n", queueEntry.options.loggingPrefix.c_str(), queueEntry.outputPath.c_str());
                } else {
                    fprintf(stderr, "[%s] Wrote cache to: %s\n", queueEntry.options.loggingPrefix.c_str(), queueEntry.outputPath.c_str());
                    std::string mapStr = results.cacheContent->mapFile();
                    std::string outFileMap = queueEntry.outputPath + ".map";
                    safeSave(mapStr.c_str(), mapStr.size(), outFileMap);
                }
                // free created cache buffer
                vm_deallocate(mach_task_self(), (vm_address_t)results.cacheContent, results.cacheLength);
            });
        } else {
            fprintf(stderr, "[%s] Skipped writing cache to: %s\n", queueEntry.options.loggingPrefix.c_str(), queueEntry.outputPath.c_str());
            vm_deallocate(mach_task_self(), (vm_address_t)results.cacheContent, results.cacheLength);
        }
    });
    
    // print any warnings
    for (const std::string& warn : warnings) {
        fprintf(stderr, "[WARNING] %s\n", warn.c_str());
    }
    
    int err = sync_volume_np(masterDstRoot.c_str(), SYNC_VOLUME_FULLSYNC | SYNC_VOLUME_WAIT);
    if (err) {
        fprintf(stderr, "Volume sync failed errnor=%d (%s)\n", err, strerror(err));
    }
    
    return !cacheBuildFailure;
}
