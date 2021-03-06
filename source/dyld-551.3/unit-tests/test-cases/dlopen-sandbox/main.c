/*
 * Copyright (c) 2015 Apple Computer, Inc. All rights reserved.
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
#include <stdio.h>  // fprintf(), NULL
#include <stdlib.h> // exit(), EXIT_SUCCESS
#include <dlfcn.h>
#include <string.h>

#include "test.h" // PASS(), FAIL(), XPASS(), XFAIL()


int main(int argc, const char* argv[])
{
	void* handle = dlopen("./libfoo.dylib", RTLD_LAZY);
	if ( handle != NULL ) {
        FAIL("dlopen-sandbox dylib should not have loaded");
		return EXIT_SUCCESS;
	}
    const char* errorMsg = dlerror();
    const char* shouldContain = argv[1];
    if ( strstr(errorMsg, shouldContain) == NULL )
        FAIL("dlopen-sandbox dylib correctly failed to loaded, but with wrong error message: %s", errorMsg);
    else
        PASS("dlopen-sandbox: %s", shouldContain);

	return EXIT_SUCCESS;
}
