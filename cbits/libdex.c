// Copyright 2019 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#include "stdio.h"
#include "stdint.h"
#include "stdlib.h"
#include "string.h"
#include "inttypes.h"

char* malloc_dex(long nbytes) {
  return malloc(nbytes);
}

char* free_dex(char* ptr) {
  free(ptr);
}

void memcpy_dex(char* dest, const char* src, long nbytes) {
  memcpy(dest, src, nbytes);
}

uint32_t rotate_left(uint32_t x, uint32_t d) {
  return (x << d) | (x >> (32 - d));
}

uint64_t apply_round(uint32_t x, uint32_t y, int rot) {
  uint64_t out;

  x = x + y;
  y = rotate_left(y, rot);
  y = x ^ y;

  out = (uint64_t) x;
  out = (out << 32) | y;
  return out;
}

uint64_t threefry2x32(uint64_t keypair, uint64_t count) {
  /* Based on jax's threefry_2x32 by Matt Johnson and Peter Hawkins */

  uint32_t k0;
  uint32_t k1;
  uint32_t k2;

  uint32_t x;
  uint32_t y;

  uint64_t out;
  int i;

  int rotations1[4] = {13, 15, 26, 6};
  int rotations2[4] = {17, 29, 16, 24};

  k0 = (uint32_t) (keypair >> 32);
  k1 = (uint32_t) keypair;
  k2 = k0 ^ k1 ^ 0x1BD11BDA;
  x = (uint32_t) (count >> 32);
  y = (uint32_t) count;

  x = x + k0;
  y = y + k1;


  for (i=0;i<4;i++) {
    count = apply_round(x, y, rotations1[i]);
    x = (uint32_t) (count >> 32);
    y = (uint32_t) count;
  }
  x = x + k1;
  y = y + k2 + 1;


  for (i=0;i<4;i++) {
    count = apply_round(x, y, rotations2[i]);
    x = (uint32_t) (count >> 32);
    y = (uint32_t) count;
  }
  x = x + k2;
  y = y + k0 + 2;

  for (i=0;i<4;i++) {
    count = apply_round(x, y, rotations1[i]);
    x = (uint32_t) (count >> 32);
    y = (uint32_t) count;
  }
  x = x + k0;
  y = y + k1 + 3;

  for (i=0;i<4;i++) {
    count = apply_round(x, y, rotations2[i]);
    x = (uint32_t) (count >> 32);
    y = (uint32_t) count;
  }
  x = x + k1;
  y = y + k2 + 4;

  for (i=0;i<4;i++) {
    count = apply_round(x, y, rotations1[i]);
    x = (uint32_t) (count >> 32);
    y = (uint32_t) count;
  }
  x = x + k2;
  y = y + k0 + 5;

  out = (uint64_t) x;
  out = (out << 32) | y;
  return out;
}

long randint(uint64_t keypair, long nmax) {
  return keypair % nmax; // TODO: correct this with rejection sampling or more bits
}

double randunif(uint64_t keypair) {
  /* Assumes 1023 offset and 52 mantissa bits and probably very platform-specific. */
  uint64_t mantissa_bits;
  uint64_t exponent_bits;
  uint64_t bits;

  mantissa_bits = keypair & ((((uint64_t) 1) << 52) - 1);
  exponent_bits = ((uint64_t) 1023) << 52;
  bits = mantissa_bits | exponent_bits;

  double out = *(double*)&bits;
  return out - 1;
}

long floorDex(double x) {
  return x;
}

int testit() {
  printf("%" PRIx64 "\n", threefry2x32(0,0));   // expected: 0x6b2001590x99ba4efe
  printf("%" PRIx64 "\n", threefry2x32(-1,-1)); // expected: 0x1cb996fc0xbb002be7
  printf("%" PRIx64 "\n", threefry2x32(
     0x13198a2e03707344,  0x243f6a8885a308d3)); // expected: 0xc4923a9c0x483df7a0
}

int main(int argc, const char* argv[]) {
  testit();
}