#!/usr/sbin/dtrace -s
/*
 * sniff.d — passive sniffer of iPhone Mirroring's AX queries.
 *
 * Hooks AXPMacPlatformElement methods inside the Mirror process and
 * emits tab-separated records on each query/return:
 *
 *   AX  <self> <attr> <ret> <b0..b7>     normal return; bytes 0..64 of obj
 *   AXN <self> <attr>                     return was nil
 *   AXT <self> <attr> <tagged>            tagged-pointer return (raw)
 *   AXS <self> <attr> <ret> <str>         deref of CFConstant/heap NSCFString
 *   AXF <self> <x> <y> <w> <h>            accessibilityFrame NSRect
 *
 * Lines without these prefixes are diagnostics — consumer drops them.
 */
#pragma D option quiet
#pragma D option strsize=512
#pragma D option switchrate=20hz
#pragma D option bufsize=8m

self uintptr_t self_ptr;
self string   attr_name;

/* ---- accessibilityAttributeValue: ---- */

/* Real CFConstantString: 16-byte aligned heap pointer.
 * Tagged NSString: low nibble has tag bits, top byte may be set. */
objc$target:AXPMacPlatformElement:-accessibilityAttributeValue?:entry
/ (arg2 & 0xf) == 0 && arg2 > 0x100000000 && arg2 < 0x0000800000000000 /
{
    self->self_ptr = arg0;
    this->p = *(uintptr_t *)copyin(arg2 + 0x10, 8);
    self->attr_name = copyinstr(this->p, 64);
}

/* Tagged-pointer attr name — emit raw value, no deref */
objc$target:AXPMacPlatformElement:-accessibilityAttributeValue?:entry
/ !((arg2 & 0xf) == 0 && arg2 > 0x100000000 && arg2 < 0x0000800000000000) /
{
    self->self_ptr = arg0;
    self->attr_name = "<tagged>";
    printf("AXET\t%p\t%lx\n", arg0, arg2);
}

objc$target:AXPMacPlatformElement:-accessibilityAttributeValue?:return
/ self->self_ptr && arg1 == 0 /
{
    printf("AXN\t%p\t%s\n", self->self_ptr, self->attr_name);
}

objc$target:AXPMacPlatformElement:-accessibilityAttributeValue?:return
/ self->self_ptr && arg1 != 0 && (arg1 & 0x8000000000000000) != 0 /
{
    printf("AXT\t%p\t%s\t%lx\n", self->self_ptr, self->attr_name, arg1);
}

objc$target:AXPMacPlatformElement:-accessibilityAttributeValue?:return
/ self->self_ptr && arg1 != 0 && (arg1 & 0x8000000000000000) == 0 /
{
    this->b0 = *(uintptr_t *)copyin(arg1, 8);
    this->b1 = *(uintptr_t *)copyin(arg1 + 0x08, 8);
    this->b2 = *(uintptr_t *)copyin(arg1 + 0x10, 8);
    this->b3 = *(uintptr_t *)copyin(arg1 + 0x18, 8);
    this->b4 = *(uintptr_t *)copyin(arg1 + 0x20, 8);
    this->b5 = *(uintptr_t *)copyin(arg1 + 0x28, 8);
    this->b6 = *(uintptr_t *)copyin(arg1 + 0x30, 8);
    this->b7 = *(uintptr_t *)copyin(arg1 + 0x38, 8);
    printf("AX\t%p\t%s\t%p\t%lx\t%lx\t%lx\t%lx\t%lx\t%lx\t%lx\t%lx\n",
        self->self_ptr, self->attr_name, arg1,
        this->b0, this->b1, this->b2, this->b3,
        this->b4, this->b5, this->b6, this->b7);
}

/* String deref — predicate filters obvious non-pointer b2 values.
 * Errors here are non-fatal: dtrace prints them on stderr; consumer drops.
 */
objc$target:AXPMacPlatformElement:-accessibilityAttributeValue?:return
/ self->self_ptr && arg1 != 0 && (arg1 & 0x8000000000000000) == 0
  && (*(uintptr_t *)copyin(arg1 + 0x10, 8)) > 0x100000000
  && (*(uintptr_t *)copyin(arg1 + 0x10, 8)) < 0x0000800000000000 /
{
    this->p = *(uintptr_t *)copyin(arg1 + 0x10, 8);
    printf("AXS\t%p\t%s\t%p\t%s\n",
        self->self_ptr, self->attr_name, arg1, copyinstr(this->p, 256));
}

/* ---- _convertTranslatorResponse:forAttribute: catches every iOS->mac attr ----
 * arg0=self, arg2=response (iOS obj), arg3=attr CFString
 * arg1 on return = converted mac value
 */
objc$target:AXPMacPlatformElement:-_convertTranslatorResponse?forAttribute?:entry
/ (arg3 & 0xf) == 0 && arg3 > 0x100000000 && arg3 < 0x0000800000000000 /
{
    self->cv_self = arg0;
    this->p = *(uintptr_t *)copyin(arg3 + 0x10, 8);
    self->cv_attr = copyinstr(this->p, 64);
}

objc$target:AXPMacPlatformElement:-_convertTranslatorResponse?forAttribute?:entry
/ !((arg3 & 0xf) == 0 && arg3 > 0x100000000 && arg3 < 0x0000800000000000) /
{
    self->cv_self = arg0;
    self->cv_attr = "<tagged>";
}

objc$target:AXPMacPlatformElement:-_convertTranslatorResponse?forAttribute?:return
/ self->cv_self && arg1 != 0 && (arg1 & 0x8000000000000000) == 0 /
{
    this->b0 = *(uintptr_t *)copyin(arg1, 8);
    this->b1 = *(uintptr_t *)copyin(arg1 + 0x08, 8);
    this->b2 = *(uintptr_t *)copyin(arg1 + 0x10, 8);
    this->b3 = *(uintptr_t *)copyin(arg1 + 0x18, 8);
    printf("CV\t%p\t%s\t%p\t%lx\t%lx\t%lx\t%lx\n",
        self->cv_self, self->cv_attr, arg1,
        this->b0, this->b1, this->b2, this->b3);
}

/* String deref of CV return when b2 looks heap-shaped */
objc$target:AXPMacPlatformElement:-_convertTranslatorResponse?forAttribute?:return
/ self->cv_self && arg1 != 0 && (arg1 & 0x8000000000000000) == 0
  && (*(uintptr_t *)copyin(arg1 + 0x10, 8)) > 0x100000000
  && (*(uintptr_t *)copyin(arg1 + 0x10, 8)) < 0x0000800000000000 /
{
    this->p = *(uintptr_t *)copyin(arg1 + 0x10, 8);
    printf("CVS\t%p\t%s\t%p\t%s\n",
        self->cv_self, self->cv_attr, arg1, copyinstr(this->p, 256));
}

objc$target:AXPMacPlatformElement:-_convertTranslatorResponse?forAttribute?:return
/ self->cv_self && arg1 != 0 && (arg1 & 0x8000000000000000) != 0 /
{
    printf("CVT\t%p\t%s\t%lx\n", self->cv_self, self->cv_attr, arg1);
}

/* ---- direct string accessors that actually exist on AXPMacPlatformElement ---- */

objc$target:AXPMacPlatformElement:-accessibilityLabel:return
/ arg1 != 0 && (arg1 & 0x8000000000000000) == 0 /
{
    this->p = *(uintptr_t *)copyin(arg1 + 0x10, 8);
    printf("LBL\t%p\t%p\t%s\n", arg0, arg1, copyinstr(this->p, 256));
}

/* Tagged-pointer NSString label — emit raw, consumer decodes. */
objc$target:AXPMacPlatformElement:-accessibilityLabel:return
/ arg1 != 0 && (arg1 & 0x8000000000000000) != 0 /
{
    printf("LBLT\t%p\t%lx\n", arg0, arg1);
}

objc$target:AXPMacPlatformElement:-accessibilityRole:return
/ arg1 != 0 && (arg1 & 0x8000000000000000) == 0 /
{
    this->p = *(uintptr_t *)copyin(arg1 + 0x10, 8);
    printf("ROL\t%p\t%p\t%s\n", arg0, arg1, copyinstr(this->p, 256));
}

objc$target:AXPMacPlatformElement:-accessibilityRole:return
/ arg1 != 0 && (arg1 & 0x8000000000000000) != 0 /
{
    printf("ROLT\t%p\t%lx\n", arg0, arg1);
}

objc$target:AXPMacPlatformElement:-accessibilityParent:return
/ arg1 != 0 /
{
    printf("PAR\t%p\t%p\n", arg0, arg1);
}

/* ---- accessibilityFrame return: NSRect by value (4 doubles in regs) ---- */

objc$target:AXPMacPlatformElement:-accessibilityFrame:return
{
    /* NSRect returned in d0..d3 on arm64. dtrace exposes via uregs[].
     * Fall back: just emit self pointer; main.go will request frame via AppleScript if needed. */
    printf("AXF\t%p\n", arg0);
}
