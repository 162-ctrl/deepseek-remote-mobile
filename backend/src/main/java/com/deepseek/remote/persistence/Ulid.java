package com.deepseek.remote.persistence;

import java.security.SecureRandom;

/**
 * Ultra-small ULID generator (M1.1 DELTA section 2: every business id is a 26-char
 * uppercase Crockford Base32 string = 10-char millisecond timestamp + 16 random chars).
 *
 * <p>Implemented in-house (no extra dependency) and thread-safe.
 */
public final class Ulid {

    /** Crockford Base32 alphabet: digits + uppercase letters, I/L/O/U removed. */
    private static final char[] ENCODING = "0123456789ABCDEFGHJKMNPQRSTVWXYZ".toCharArray();

    private static final SecureRandom RANDOM = new SecureRandom();

    private Ulid() {
    }

    /** Allocates one 26-character id. */
    public static String newId() {
        long time = System.currentTimeMillis();
        char[] chars = new char[26];

        // 10 chars = 50 bit slots, but the timestamp only uses the 48 low bits.
        for (int i = 9; i >= 0; i--) {
            chars[i] = ENCODING[(int) (time & 0x1FL)];
            time >>>= 5;
        }

        // 80 random bits = 16 chars * 5 bits.
        byte[] random = new byte[10];
        RANDOM.nextBytes(random);
        for (int i = 0; i < 16; i++) {
            int value = 0;
            for (int bit = 0; bit < 5; bit++) {
                int index = i * 5 + bit;
                int current = (random[index >>> 3] >>> (7 - (index & 7))) & 1;
                value = (value << 1) | current;
            }
            chars[10 + i] = ENCODING[value];
        }
        return new String(chars);
    }

    /** True when the value looks like an id produced by this class (26 chars, valid alphabet). */
    public static boolean isValid(String id) {
        if (id == null || id.length() != 26) {
            return false;
        }
        for (int i = 0; i < id.length(); i++) {
            char c = id.charAt(i);
            boolean found = false;
            for (char candidate : ENCODING) {
                if (candidate == c) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                return false;
            }
        }
        return true;
    }
}
