'use client'

import { MoreHorizontal } from 'lucide-react'
import { startTransition, useActionState, useEffect, useState } from 'react'
import { toast } from 'sonner'

import {
  initialUserActionState,
  userAction,
  type UserActionState,
} from '@/app/(dashboard)/users/actions'
import { Button } from '@/components/ui/button'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from '@/components/ui/dropdown-menu'
import type { AdminUserRow, UserActionIntent } from '@/lib/users'

/**
 * Row menu for /users.
 *
 * The disabled states here are a courtesy only — `userAction` re-runs
 * `requireAdmin()` and `checkUserActionAllowed()` server-side on every submit.
 *
 * The action is dispatched programmatically rather than through `<form action>`:
 * both the dropdown content and the dialog render in portals and unmount on
 * select/close, which would tear the submit button out of the document before the
 * browser ran the form's default action.
 */
export function UserRowActions({ row }: { row: AdminUserRow }) {
  const [state, dispatch, pending] = useActionState<UserActionState, FormData>(
    userAction,
    initialUserActionState,
  )
  const [confirmOpen, setConfirmOpen] = useState(false)

  useEffect(() => {
    if (state.status === 'idle' || state.message === null) return

    if (state.status === 'success') {
      toast.success(state.message)
    } else {
      toast.error(state.message)
    }
  }, [state])

  function submit(intent: UserActionIntent) {
    const formData = new FormData()
    formData.set('userId', row.id)
    formData.set('intent', intent)
    startTransition(() => {
      dispatch(formData)
    })
  }

  const locked = row.isAdmin || row.isSelf
  const lockReason = row.isSelf
    ? 'Kendi hesabınız üzerinde işlem yapamazsınız.'
    : 'Yönetici hesapları panelden yönetilemez; önce SQL ile admin_users satırı silinmelidir.'

  return (
    <div className="flex justify-end">
      <DropdownMenu>
        <DropdownMenuTrigger asChild>
          <Button
            type="button"
            variant="ghost"
            size="icon"
            disabled={pending}
            aria-label={`${row.email ?? row.id} için işlemler`}
          >
            <MoreHorizontal aria-hidden="true" />
          </Button>
        </DropdownMenuTrigger>

        <DropdownMenuContent align="end">
          <DropdownMenuItem
            disabled={locked || pending}
            onSelect={() => submit(row.status === 'banned' ? 'unban' : 'ban')}
          >
            {row.status === 'banned' ? 'Yasağı kaldır' : 'Yasakla'}
          </DropdownMenuItem>

          <DropdownMenuSeparator />

          <DropdownMenuItem
            variant="destructive"
            disabled={locked || pending}
            onSelect={(event) => {
              event.preventDefault()
              setConfirmOpen(true)
            }}
          >
            Sil
          </DropdownMenuItem>

          {locked ? (
            <p className="text-muted-foreground max-w-56 px-2 py-1.5 text-xs">{lockReason}</p>
          ) : null}
        </DropdownMenuContent>
      </DropdownMenu>

      <Dialog open={confirmOpen} onOpenChange={setConfirmOpen}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Kullanıcıyı sil</DialogTitle>
            <DialogDescription asChild>
              <div className="space-y-2 text-left">
                <p>
                  <span className="text-foreground font-medium">{row.email ?? row.id}</span> hesabı
                  kalıcı olarak silinecek.
                </p>
                <p>
                  Bu işlem <strong>geri alınamaz.</strong> Yabancı anahtar kademeli silme (FK
                  cascade) nedeniyle kullanıcının <em>şifreli</em> jetonları, anahtar öznitelikleri
                  ve cihaz kayıtları da silinir. Panel bu verilerin içeriğini hiçbir zaman göremez;
                  yalnızca kaydı kaldırır.
                </p>
              </div>
            </DialogDescription>
          </DialogHeader>

          <DialogFooter>
            <Button
              type="button"
              variant="outline"
              onClick={() => setConfirmOpen(false)}
              disabled={pending}
            >
              Vazgeç
            </Button>
            <Button
              type="button"
              variant="destructive"
              disabled={locked || pending}
              onClick={() => {
                submit('delete')
                setConfirmOpen(false)
              }}
            >
              {pending ? 'Siliniyor…' : 'Kalıcı olarak sil'}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  )
}
