MainForm.cbWritable.State=2
MainForm.cbCopyOnWrite.State=2
local hxl=string.len(MainForm.FromAddress.Text)
MainForm.ToAddress.Text='7'..string.rep('f',hxl-1)