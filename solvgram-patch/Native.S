.text
.p2align 2
.globl _SGNativeStart
// C ABI: signal, next, completed, native Swift context, Signal.start address.
// Return: Disposable's object and witness-table words in x0/x1.
_SGNativeStart:
    stp x29, x30, [sp, #-32]!
    stp x20, x19, [sp, #16]
    mov x29, sp
    mov x8, x4
    mov x20, x0
    mov x4, x2
    mov x5, x3
    mov x0, x1
    mov x1, x3
    mov x2, xzr
    mov x3, xzr
    blr x8
    ldp x20, x19, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

.globl _SGNativePreviewNext
_SGNativePreviewNext:
    mov x1, x20
    b _SGPreviewConsumeValue

.globl _SGNativePreviewCompleted
_SGNativePreviewCompleted:
    mov x0, x20
    b _SGPreviewConsumeComplete

.globl _SGNativeDispose
_SGNativeDispose:
    stp x20, x30, [sp, #-16]!
    mov x20, x0
    ldr x8, [x1, #8]
    blr x8
    ldp x20, x30, [sp], #16
    ret
