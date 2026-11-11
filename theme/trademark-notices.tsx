import { jsx, jsxs } from 'react/jsx-runtime'

import './trademark-notices.css'

const linuxFoundationNotice =
  'OpenTelemetry® is a registered trademark of The Linux Foundation.'
const independenceNotice =
  'Alauda is an independent vendor. This product is not affiliated with, endorsed by, or sponsored by The Linux Foundation. All trademarks are the property of their respective owners and are used here for identification purposes only.'

function NoticeText() {
  return jsxs('div', {
    children: [jsx('p', { children: linuxFoundationNotice }), jsx('p', { children: independenceNotice })],
  })
}

export function TrademarkNotices() {
  return jsxs('footer', {
    className: 'alauda-trademark-notices',
    children: [
      jsxs('details', {
        children: [
          jsx('summary', { children: 'Trademark notices' }),
          jsx(NoticeText, {}),
        ],
      }),
      jsx('div', {
        className: 'alauda-trademark-notices-print',
        'aria-hidden': true,
        children: jsx(NoticeText, {}),
      }),
    ],
  })
}
