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
import { formatPayload, PAYLOAD_MAX_BYTES, type FeatureFlag } from '@/lib/flags'

export function FlagPayloadDialog({ flag }: { flag: FeatureFlag }) {
  const [open, setOpen] = useState(false)

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
    <Dialog open={open} onOpenChange={setOpen}>
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
              disabled={pending}
            />
          </div>

          <DialogFooter>
            <Button type="button" variant="outline" onClick={() => setOpen(false)} disabled={pending}>
              Vazgeç
            </Button>
            <Button type="submit" disabled={pending}>
              {pending ? 'Kaydediliyor…' : 'Kaydet'}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  )
}
