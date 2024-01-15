local f=function()
				local mFrm=getMemoryViewForm()
				local asf=mFrm.frmAssemblyScan
				if asf==nil then return end
				local pid=getOpenedProcessID()
				local mds=enumModules(pid)
				local pName=''
				for i=1, #mds do
					local mi=mds[i]
					local mName=mi.Name
					local m_pid=getProcessIDFromProcessName(mName)
					if m_pid==pid then
						pName=mName
						break
					end
				end
				if pName~='' then
					local ada=getAddress(pName)
					local adz=ada+getModuleSize(pName)-1
					asf.edtFrom.Text=string.format('%X',ada)
					asf.edtTo.Text=string.format('%X',adz)
					asf.mAssemblerSearch.lines.Text=''
				end
end

local sa_tmr2=createTimer(getMainForm())
local sa_f2=function(sa_tmr2)
	local mfr=getMemoryViewForm()
	local asf=mfr.frmAssemblyScan
	if asf~=nil then
		sa_tmr2.destroy()
		asf.OnShow=f
		asf.close()
	end
end

sa_tmr2.Interval=1
sa_tmr2.onTimer=sa_f2

local sa_tmr=createTimer(getMainForm())
local sa_f=function(sa_tmr)
						sa_tmr.destroy()
						getMemoryViewForm().Assemblycode1.doClick()
end
sa_tmr.Interval=1
sa_tmr.onTimer=sa_f


