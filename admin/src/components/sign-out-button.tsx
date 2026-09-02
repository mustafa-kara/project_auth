'use client'

import { LogOut } from 'lucide-react'
import { useTransition } from 'react'

import { signOutAction } from '@/app/auth/actions'
import { Button } from '@/components/ui/button'

export function SignOutButton() {
  const [pending, startTransition] = useTransition()

  return (
    <Button
      variant="outline"
      size="sm"
      disabled={pending}
      onClick={() => startTransition(() => void signOutAction())}
    >
      <LogOut aria-hidden="true" />
      {pending ? 'Çıkılıyor…' : 'Çıkış yap'}
    </Button>
  )
}
