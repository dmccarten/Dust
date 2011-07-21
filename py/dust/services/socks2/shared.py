import monocle
from monocle import _o, Return

from monocle.stack.network import ConnectionLost

from dust.core.util import encode
from dust.extensions.lite.lite_socket import lite_socket
from dust.crypto.keys import KeyManager

@_o
def pump(input, output, transform, debug=False):
  while True:
    try:
      message = yield input.read_some()
#      message=yield input.read(1)
      if not message or len(message)==0:
        print('0 from '+str(input)+' '+str(type(message)))
        raise(Exception())
#        message=yield input.read(1)
      if debug:
        print('receive '+str(len(message)))
    except ConnectionLost:
      print('Client connection closed')
      output.close()
      break
    except IOError:
      output.close()
      break

    if transform:
      messages=transform(message)
    else:
      messages=[message]

    for x in range(len(messages)):
      message=messages[x]
      if debug:
        print('sending '+str(len(message))+' - '+str(x+1)+'/'+str(len(messages)))
      try:
        yield output.write(message)
      except ConnectionLost:
        print('Connection lost')
        input.close()
        return
      except IOError:
        print('IOError')
        input.close()
        return
      except Exception, e:
        print('Exception')
        print(e)
        input.close()
        return

class DustCoder(object):
  def __init__(self, myAddr, dest):
    print('DustCoder: '+str(myAddr)+' '+str(dest))
    self.duster=lite_socket(KeyManager())
    self.duster.setAddress(myAddr)
    self.dest=dest
    self.inbuffer=b''

  def dustPacket(self, message):
    if len(message)<1024:
      messages=[message]
    else:
      messages=[]
      for x in range(len(message)/1024):
        messages.append(message[:1024])
        message=message[1024:]
      if len(message)>0:
        messages.append(message)
    results=[]
    for data in messages:
      result=self.duster.encodePacket(self.dest, data).packet
#      print('Sending packet '+str(len(result))+' - '+str(len(data)))
      results.append(result)
    return results

  def dirtyPacket(self, data):
    self.inbuffer=self.inbuffer+data
    results=[]

    try:
      packet=self.duster.decodePacket(self.dest, data)
    except:
      packet=None

    if packet:
      results.append(packet.data)
      self.inbuffer=b''

      if packet.remaining and len(packet.remaining)>0:
        results=results+self.dirtyPacket(packet.remaining)

    return results
