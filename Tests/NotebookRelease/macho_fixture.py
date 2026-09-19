"""Synthetic signed Mach-O for compiler packaging guards; not executable."""
import struct

def executable(signature=b'unsigned-signature', library='/usr/lib/libSystem.B.dylib'):
    dylib=library.encode()+b'\0';dylib+=bytes((-len(dylib))%8)
    linkedit=struct.pack('<II16sQQQQiiII',0x19,72,b'__LINKEDIT',0,4096,256,256+len(signature),7,1,0,0)
    version=struct.pack('<IIIIII',0x32,24,1,27<<16,27<<16,0)
    imports=struct.pack('<IIIIII',0xC,24+len(dylib),24,0,0,0)+dylib
    commands=linkedit+version+imports+struct.pack('<IIII',0x1D,16,256,len(signature))
    header=struct.pack('<IiiIIIII',0xFEEDFACF,0x0100000C,0,2,4,len(commands),0,0)
    prefix=header+commands;return prefix+bytes(256-len(prefix))+signature

