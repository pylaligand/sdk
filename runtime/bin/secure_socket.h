// Copyright (c) 2012, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

#ifndef BIN_SECURE_SOCKET_H_
#define BIN_SECURE_SOCKET_H_

#if defined(DART_IO_DISABLED) || defined(DART_IO_SECURE_SOCKET_DISABLED)
#error "secure_socket.h can only be included on builds with SSL enabled"
#endif

#include "platform/globals.h"
#if defined(TARGET_OS_ANDROID) || \
    defined(TARGET_OS_LINUX)   || \
    defined(TARGET_OS_WINDOWS)
#include "bin/secure_socket_boringssl.h"
#elif defined(TARGET_OS_MACOS)
#include "bin/secure_socket_macos.h"
#else
#error Unknown target os.
#endif

#endif  // BIN_SECURE_SOCKET_H_
