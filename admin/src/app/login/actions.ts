'use server'

import { redirect } from 'next/navigation'
import { z } from 'zod'

import { isAdminClaims } from '@/lib/auth'
import { createClient } from '@/lib/supabase/server'

export interface LoginState {
  error: string | null
}

export const initialLoginState: LoginState = { error: null }

const credentialsSchema = z.object({
  email: z.email({ message: 'Geçerli bir e-posta adresi girin.' }),
  password: z.string().min(1, { message: 'Parola boş olamaz.' }),
})

export async function signInAction(
  _prevState: LoginState,
  formData: FormData,
): Promise<LoginState> {
  const parsed = credentialsSchema.safeParse({
    email: formData.get('email'),
    password: formData.get('password'),
  })

  if (!parsed.success) {
    return { error: parsed.error.issues[0]?.message ?? 'Geçersiz giriş bilgileri.' }
  }

  const supabase = await createClient()
  const { error } = await supabase.auth.signInWithPassword(parsed.data)

  if (error) {
    // Deliberately generic: never reveal whether the address exists.
    return { error: 'E-posta veya parola hatalı.' }
  }

  // The session now exists — but a session is not authorization. Verify the
  // JWKS-signed `app_metadata.admin` claim before letting anyone past /login.
  const { data: claimsData, error: claimsError } = await supabase.auth.getClaims()

  if (claimsError || !isAdminClaims(claimsData?.claims)) {
    await supabase.auth.signOut()
    return { error: 'Bu hesap yönetici değil.' }
  }

  redirect('/')
}
