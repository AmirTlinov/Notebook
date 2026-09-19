"""Inspect pinned arm64 compiler executables independently of re-signing."""
import hashlib, struct
def sha(data): return hashlib.sha256(data).hexdigest()

def macho(data, minimum_os="27.0"):
    """Inspect architecture/imports and hash code independently of re-signing.

    Codesign changes LC_CODE_SIGNATURE and __LINKEDIT allocation. Normalize
    only those lengths/pointers and exclude the signature blob. Every preceding
    executable byte and all other load commands remain in the fingerprint.
    """
    if len(data)<32:raise RuntimeError("Compiler has no Mach-O header")
    magic,cpu,subtype,kind,count,size,flags,reserved=struct.unpack_from('<IiiIIIII',data)
    if magic!=0xFEEDFACF or cpu!=0x0100000C or kind!=2 or count>4096 or size>len(data)-32:raise RuntimeError("Compiler must be thin arm64 Mach-O executable")
    output=bytearray(data);cursor=32;signature=None;platform=None;minimum=None;libraries=[]
    for _ in range(count):
        if cursor+8>32+size:raise RuntimeError("Truncated compiler load commands")
        command,length=struct.unpack_from('<II',data,cursor)
        if length<8 or cursor+length>32+size:raise RuntimeError("Invalid compiler load command size")
        if command==0x1D:
            if length!=16 or signature is not None:raise RuntimeError("Invalid compiler code signature command")
            start,amount=struct.unpack_from('<II',data,cursor+8)
            if start<32+size or amount==0 or start+amount!=len(data):raise RuntimeError("Compiler signature does not end the executable")
            signature=start;output[cursor+8:cursor+16]=bytes(8)
        elif command==0x19:
            if length<72:raise RuntimeError("Truncated compiler segment")
            name=data[cursor+8:cursor+24].rstrip(b'\0')
            if name==b'__LINKEDIT':output[cursor+32:cursor+40]=bytes(8);output[cursor+48:cursor+56]=bytes(8)
        elif command==0x32:
            if length<24:raise RuntimeError("Truncated compiler build version")
            platform,minimum=struct.unpack_from('<II',data,cursor+8)
        elif command in (0xC,0x80000018,0x8000001F,0x20,0x80000023):
            if length<24:raise RuntimeError("Truncated compiler dylib command")
            offset=struct.unpack_from('<I',data,cursor+8)[0]
            if not 24<=offset<length:raise RuntimeError("Invalid dylib name")
            library=data[cursor+offset:cursor+length].split(b'\0',1)[0].decode('utf8')
            if not library.startswith(('/System/Library/','/usr/lib/')):raise RuntimeError("Non-system compiler library: "+library)
            libraries.append(library)
        elif command==0x8000001C:raise RuntimeError("Compiler cannot depend on a runtime library search path")
        cursor+=length
    if cursor!=32+size or signature is None or platform!=1 or minimum!=sum(int(part) << shift for part,shift in zip(minimum_os.split("."),[16,8,0])):raise RuntimeError("Compiler must target signed macOS 27.0")
    return {"architecture":"arm64","platform":"MACOS","minimumOS":minimum_os,
            "systemLibraries":libraries,"codeSHA256":sha(output[:signature])}

