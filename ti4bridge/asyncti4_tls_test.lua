--[[ ===========================================================================
  TLS 1.2 control test for TTS
  ---------------------------------------------------------------------------
  Button 1 hits bot.asyncti4.com directly (TLS 1.3-only) -> expected to FAIL
  with a TLS-layer error ("Unable to complete SSL connection").

  Button 2 hits raw.githubusercontent.com, which serves over TLS 1.2 with a
  Let's Encrypt cert -- the SAME certificate authority async uses. A 200 here
  proves TWO things at once: (a) TTS can negotiate TLS 1.2, and (b) TTS trusts
  the Let's Encrypt / ISRG root. So a fail on #1 + success on #2 == the only
  thing blocking async is its TLS-1.3-only floor; enabling 1.2 will fix it.
=========================================================================== ]]

local DIRECT = 'https://bot.asyncti4.com/api/public/game/pbd24975/web-data' -- TLS 1.3 only
local LE     = 'https://raw.githubusercontent.com/DangerousGoods/TI4-TTS/main/README.md' -- TLS 1.2 + Let's Encrypt

function onLoad()
    self.createButton({
        label = '1) async DIRECT (TLS 1.3)', click_function = 'testDirect', function_owner = self,
        position = { x = 0, y = 0.3, z = -0.45 }, width = 2300, height = 350, font_size = 150,
        color = { 0.6, 0.15, 0.15 }, font_color = { 1, 1, 1 },
    })
    self.createButton({
        label = "2) TLS 1.2 + Let's Encrypt", click_function = 'testLE', function_owner = self,
        position = { x = 0, y = 0.3, z = 0.5 }, width = 2300, height = 350, font_size = 150,
        color = { 0.15, 0.5, 0.15 }, font_color = { 1, 1, 1 },
    })
end

function testDirect() runTest('async DIRECT (TLS 1.3)', DIRECT) end
function testLE()     runTest("TLS 1.2 + Let's Encrypt", LE) end

function runTest(label, url)
    broadcastToAll('TLS test: requesting ' .. label .. ' ...', { 0.8, 0.8, 0.8 })
    WebRequest.get(url, function(r)
        local code = r.response_code
        if r.is_error then
            local msg = string.format('TLS-LAYER FAIL  %s  ::  %s', label, tostring(r.error))
            broadcastToAll(msg, { 1, 0.3, 0.3 })
            print('[TLS test] ' .. msg)
        else
            local n = r.text and #r.text or 0
            local msg = string.format('CONNECTED  %s  ::  http %s, %d bytes', label, tostring(code), n)
            local col = (code and code >= 200 and code < 300) and { 0.4, 1, 0.4 } or { 1, 0.8, 0.3 }
            broadcastToAll(msg, col)
            print('[TLS test] ' .. msg)
        end
    end)
end
