module DAQespmcp

# Write your package code here.
using PyCall
using AbstractDAQs
import Dates: DateTime, now
import DataStructures: OrderedDict
export EspMcp, daqconfigdev, daqstop, daqacquire, daqaddinput
export daqstart, daqread, samplesread, isreading
export daqchannels, numchannels


mutable struct EspMcp <: AbstractDAQ
    devname::String
    Eref::Float64
    ip::String
    port::Int32
    server::PyObject
    conf::DAQConfig
    chans::Vector{Int}
    channames::Vector{String}
    chanidx::OrderedDict{String,Int}
    time::DateTime
end

function EspMcp(devname, ip, port=9541, Eref=2.5)
    xmlrpc = pyimport("xmlrpc.client")
    server = xmlrpc.ServerProxy("http://$ip:$port")
    conf = DAQConfig(devname=devname, ip=ip, model="ESPMCPdaq")
    
    chans = collect(1:32)
    channames = string.('E', numstring.(chans, 2))
    chanidx = OrderedDict{String,Int}()
    for (i,ch) in enumerate(channames)
        chanidx[ch] = i
    end

    EspMcp(devname, Eref, ip, port, server, conf,
              chans, channames, chanidx,
              now())

    
end


function AbstractDAQs.daqaddinput(dev::EspMcp, chans=1:32; names="E")
    cmin, cmax = extrema(chans)
    if cmin < 1 || cmax > 32
        throw(ArgumentError("Only channels 1-32 are available to EspMcp"))
    end

    if isa(names, AbstractString) || isa(names, Symbol)
        chn = string(names) .* numstring.(chans)
    elseif length(names) == length(chans)
        chn = string.(names)
    else
        throw(ArgumentError("Argument `names` should have length 1 or the length of `chans`"))
    end

    dev.chans = collect(chans)
    dev.channames = chn
    n = length(chans)
    chanidx = OrderedDict{String,Int}()
    for i in 1:n
        chanidx[chn[i]] = i
    end
    dev.chanidx = chanidx
    

    return
    
end

AbstractDAQs.devtype(dev::EspMcp) = "EspMcp"

function AbstractDAQs.daqconfigdev(dev::EspMcp; kw...)

    if haskey(kw, :avg)
        avg = round(Int, kw[:avg])
        dev.server["avg"](avg)
        dev.conf.ipars["avg"] = avg
    end

    if haskey(kw, :fps)
        fps = round(Int, kw[:fps])
        dev.server["fps"](fps)
        dev.conf.ipars["fps"] = fps
    end

    if haskey(kw, :period)
        period = round(Int, kw[:period])
        dev.server["period"](period)
        dev.conf.ipars["period"] = period
    end
    
end

function AbstractDAQs.daqstop(dev::EspMcp)
    dev.server["stop"]()
end

function parse_xmlrpc_response(x, Eref)
    nsamples = x[2]
    nchans = x[3]
    freq = x[4]
    E = reshape(reinterpret(UInt16, read(IOBuffer(x[1].data),
                                         2*nsamples*nchans)) .* Eref/4095,
                (nchans, nsamples))
    return E, freq
end


    

function AbstractDAQs.daqacquire(dev::EspMcp)
    dev.time = now()
    E,f =   parse_xmlrpc_response(dev.server["scanbin"](), dev.Eref)
    return MeasData{Matrix{Float64}}(devname(dev), devtype(dev),
                                     dev.time, f, E[dev.chans,:], dev.chanidx)
end

function AbstractDAQs.daqstart(dev::EspMcp)
    dev.time = now()
    dev.server["start"]()
    
end

function AbstractDAQs.daqread(dev::EspMcp)
    E,f =   parse_xmlrpc_response(dev.server["readbin"](), dev.Eref)
    return MeasData{Matrix{Float64}}(devname(dev), devtype(dev),
                                     dev.time, f, E[dev.chans,:], dev.chanidx)
end

function AbstractDAQs.isreading(dev::EspMcp)
    return dev.server["isacquiring"]()
end

function AbstractDAQs.samplesread(dev::EspMcp)
    return dev.server["samplesread"]()
end

AbstractDAQs.daqchannels(dev::EspMcp) = dev.channames
AbstractDAQs.numchannels(dev::EspMcp) = length(dev.chans)

    
end
