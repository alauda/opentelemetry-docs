import { Fragment, jsx, jsxs } from 'react/jsx-runtime'

import { Layout as DoomLayout } from '@alauda/doom/theme'

import { TrademarkNotices } from './trademark-notices'

export function Layout() {
  return jsxs(Fragment, {
    children: [jsx(DoomLayout, {}), jsx(TrademarkNotices, {})],
  })
}
