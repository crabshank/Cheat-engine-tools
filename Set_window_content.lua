local function getMember(v,t)
	local out=v
	for i=1,#t do
		out=out[ t[i] ]
	end
	return out
end

local function setMember(v,t,n)
	local out=v
	local lt=#t
	for i=1,lt do
		if i==lt then
			out[ t[i] ]=n
			return
		else
			out=out[ t[i] ]
		end
	end
end

local membersTable={ -- setup windows to change here
	{shortcut={'Assemblycode1'}, form={'frmAssemblyScan'}, event={'OnShow','form'}},
	{shortcut={'Savedisassemledoutput1'}, form={'frmSavedisassembly'}, event={'OnClick','shortcut'}}
}

local lix=1 -- counter for windows set

local function getToFromAddresses()
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
		return {ada,adz}
	else
		return nil
	end
end

local function toFromExe(x,f,t,xtra,forceShow)
	local mFrm=getMemoryViewForm()
	local asf=getMember(mFrm,membersTable[x].form)
	if asf==nil then return end
	if forceShow==true then
		asf.Show()
	end
	local d=getToFromAddresses()
	if d~=nil then
		setMember(asf,f,string.format('%X',d[1]))
		setMember(asf,t,string.format('%X',d[2]))
		if xtra~=nil then
			for i=1, #xtra do
				local xi=xtra[i]
				local xln=getMember(asf,xi.path)
				xln=xi.content
			end
		end
	end
end

membersTable[1].func=function()
	toFromExe(1,{'edtFrom','Text'},{'edtTo','Text'},{{path={'mAssemblerSearch','lines','Text'},content=''}},false)
end

membersTable[2].func=function()
	toFromExe(2,{'Edit1','Text'},{'Edit2','Text'},nil,true)
end

local function setupWnd(membersTable,lix)
	local sa_tmr2=createTimer(getMainForm())
	local sa_f2=function(sa_tmr2)
		local mLix=membersTable[lix]
		local mfr=getMemoryViewForm()
		local asf=getMember(mfr,mLix.form)
		if asf~=nil then
			sa_tmr2.destroy()
			getMember(mfr,mLix[ mLix.event[2] ])[mLix.event[1]]=mLix.func
			asf.close()
			lix=lix+1
			if lix<=#membersTable then
				setupWnd(membersTable,lix)
			end
		end
	end

	sa_tmr2.Interval=1
	sa_tmr2.onTimer=sa_f2

	local sa_tmr=createTimer(getMainForm())
	local sa_f=function(sa_tmr)
		sa_tmr.destroy()
		getMember(getMemoryViewForm(),membersTable[lix].shortcut).doClick()
	end
	sa_tmr.Interval=1
	sa_tmr.onTimer=sa_f
end

setupWnd(membersTable,lix)