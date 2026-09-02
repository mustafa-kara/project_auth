'use client'

import { useState, useTransition } from 'react'
import { toast } from 'sonner'

import { toggleFlagAction } from '@/app/(dashboard)/flags/actions'
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from '@/components/ui/alert-dialog'
import { Switch } from '@/components/ui/switch'
import { TOKEN_SYNC_FLAG_KEY, TOKEN_SYNC_WARNING, type FeatureFlag } from '@/lib/flags'

/**
 * Row switch. Turning the `token_sync_enabled` kill switch OFF asks for confirmation
 * first — that single write stops token sync on every installed client.
 */
export function FlagToggle({ flag }: { flag: FeatureFlag }) {
  const [confirming, setConfirming] = useState(false)
  const [pending, startTransition] = useTransition()

  const isKillSwitch = flag.key === TOKEN_SYNC_FLAG_KEY

  function run(next: boolean) {
    startTransition(async () => {
      const result = await toggleFlagAction(flag.key, next)
      if (result.status === 'success') {
        toast.success(result.message)
        setConfirming(false)
      } else if (result.status === 'error') {
        toast.error(result.message)
      }
    })
  }

  function onCheckedChange(next: boolean) {
    if (isKillSwitch && !next) {
      setConfirming(true)
      return
    }
    run(next)
  }

  return (
    <>
      <Switch
        checked={flag.enabled}
        onCheckedChange={onCheckedChange}
        disabled={pending}
        aria-label={`${flag.key} bayrağı`}
      />

      <AlertDialog open={confirming} onOpenChange={setConfirming}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>Token senkronu kapatılsın mı?</AlertDialogTitle>
            <AlertDialogDescription>
              {TOKEN_SYNC_WARNING} İstemciler bayrağı bir sonraki yenilemede görür; yerel kasalar
              etkilenmez, yalnızca sunucu senkronu durur.
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel disabled={pending}>Vazgeç</AlertDialogCancel>
            <AlertDialogAction
              onClick={(event) => {
                event.preventDefault()
                run(false)
              }}
              disabled={pending}
            >
              {pending ? 'Kapatılıyor…' : 'Kapat'}
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </>
  )
}
