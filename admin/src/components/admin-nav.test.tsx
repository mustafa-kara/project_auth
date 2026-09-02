import { render, screen } from '@testing-library/react'
import { describe, expect, it, vi } from 'vitest'

import { AdminNav } from '@/components/admin-nav'
import { NAV_ITEMS } from '@/lib/nav'

const pathname = vi.hoisted(() => ({ value: '/' }))

vi.mock('next/navigation', () => ({
  usePathname: () => pathname.value,
}))

describe('AdminNav', () => {
  it('renders every nav item in Turkish', () => {
    pathname.value = '/'
    render(<AdminNav />)

    for (const item of NAV_ITEMS) {
      expect(screen.getByRole('link', { name: item.label })).toHaveAttribute('href', item.href)
    }
    expect(screen.getByRole('link', { name: 'Denetim Kaydı' })).toBeInTheDocument()
  })

  it('marks only the active route with aria-current', () => {
    pathname.value = '/announcements'
    render(<AdminNav />)

    expect(screen.getByRole('link', { name: 'Duyurular' })).toHaveAttribute('aria-current', 'page')
    expect(screen.getByRole('link', { name: 'Panel' })).not.toHaveAttribute('aria-current')
  })
})
