'use client'

import { useActionState, useState } from 'react'
import { toast } from 'sonner'

import {
  initialActionState,
  updateFlagPayloadAction,
  type ActionState,
} from '@/app/(dashboard)/flags/actions'
import { Button } from '@/components/ui/button'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
  DialogTrigger,
} from '@/components/ui/dialog'
import { Label } from '@/components/ui/label'
import { Textarea } from '@/components/ui/textarea'
import {
  formatPayload,
  PAYLOAD_MAX_BYTES,
  PAYLOAD_UNUSABLE_WARNING,
  type FeatureFlag,
} from '@/lib/flags'

export function FlagPayloadDialog({ flag }: { flag: FeatureFlag }) {
  const [open, setOpen] = useState(false)

  // When the column holds something the client cannot use (an array, a scalar),
  // `flag.payload` is the coerced `null` — so the textarea would render EMPTY and
  // an untouched save would silently erase the stored value. Save stays disabled
  // until the admin actually types something, making the destruction deliberate.
  const [touched, setTouched] = useState(false)
  const blockedUntilEdited = flag.payloadUnusable && !touched

  // Result handled inline, not in an effect (see announcement-form-dialog.tsx).
  const [, formAction, pending] = useActionState(
    async (previous: ActionState, formData: FormData) => {
      const result = await updateFlagPayloadAction(previous, formData)
      if (result.status === 'success') {
        toast.success(result.message)
        setOpen(false)
      } else if (result.status === 'error') {
        toast.error(result.message)
      }
      return result
    },
    initialActionState,
  )

  return (
    <Dialog
      open={open}
      onOpenChange={(next) => {
        setOpen(next)
        if (!next) setTouched(false)
      }}
    >
      <DialogTrigger asChild>
        <Button variant="ghost" size="sm">
          Payload
        </Button>
      </DialogTrigger>

      <DialogContent className="sm:max-w-lg">
        <DialogHeader>
          <DialogTitle>
            <code>{flag.key}</code> payload
          </DialogTitle>
          <DialogDescription>
            JSON nesnesi ya da boş (NULL). Dizi ve skaler değerler istemcide yok sayılır, bu yüzden
            kabul edilmez. En fazla {PAYLOAD_MAX_BYTES / 1024} KiB.
          </DialogDescription>
        </DialogHeader>

        <form action={formAction} className="flex flex-col gap-4">
          <input type="hidden" name="key" value={flag.key} />

          {flag.payloadUnusable ? (
            <p
              role="alert"
              className="border-destructive/40 bg-destructive/10 text-destructive rounded-md border p-3 text-xs"
            >
              {PAYLOAD_UNUSABLE_WARNING}
            </p>
          ) : null}

          <div className="flex flex-col gap-2">
            <Label htmlFor={`payload-${flag.key}`}>Payload (JSON)</Label>
            <Textarea
              id={`payload-${flag.key}`}
              name="payload"
              rows={10}
              spellCheck={false}
              className="font-mono text-xs"
              placeholder="{}"
              defaultValue={formatPayload(flag.payload)}
              onChange={() => setTouched(true)}
              disabled={pending}
            />
          </div>

          <DialogFooter>
            <Button type="button" variant="outline" onClick={() => setOpen(false)} disabled={pending}>
              Vazgeç
            </Button>
            <Button type="submit" disabled={pending || blockedUntilEdited}>
              {pending ? 'Kaydediliyor…' : 'Kaydet'}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  )
}
